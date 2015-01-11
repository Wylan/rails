module ActiveRecord
  module ConnectionAdapters
    class TransactionState
      attr_reader :parent

      VALID_STATES = Set.new([:committed, :rolledback, nil])

      def initialize(state = nil)
        @state = state
        @parent = nil
      end

      def finalized?
        @state
      end

      def committed?
        @state == :committed
      end

      def rolledback?
        @state == :rolledback
      end

      def completed?
        committed? || rolledback?
      end

      def set_state(state)
        if !VALID_STATES.include?(state)
          raise ArgumentError, "Invalid transaction state: #{state}"
        end
        @state = state
      end
    end

    class NullTransaction #:nodoc:
      def initialize; end
      def closed?; true; end
      def open?; false; end
      def joinable?; false; end
      def add_record(record); end
    end

    class Transaction #:nodoc:

      attr_reader :connection, :state, :records, :savepoint_name
      attr_writer :joinable

      def initialize(connection, options)
        @connection = connection
        @state = TransactionState.new
        @records = []
        @joinable = options.fetch(:joinable, true)
        @top_level = options.fetch(:top_level, false)
      end

      def add_record(record)
        if record.has_transactional_callbacks?
          records << record
        else
          record.set_transaction_state(@state)
        end
      end

      def rollback
        @state.set_state(:rolledback)
      end

      def rollback_records
        ite = records.uniq
        while record = ite.shift
          record.rolledback!(force_restore_state: full_rollback?)
        end
      ensure
        ite.each do |i|
          i.rolledback!(force_restore_state: full_rollback?, should_run_callbacks: false)
        end
      end

      def commit
        @state.set_state(:committed)
      end

      def commit_records
        ite = records.uniq
        while record = ite.shift
          record.committed!
        end
      ensure
        ite.each do |i|
          i.committed!(should_run_callbacks: false)
        end
      end

      def full_rollback?; true; end
      def joinable?; @joinable; end
      def top_level?; @top_level; end
      def closed?; false; end
      def open?; !closed?; end
    end

    class SavepointTransaction < Transaction

      def initialize(connection, savepoint_name, options)
        super(connection, options)
        if options[:isolation]
          raise ActiveRecord::TransactionIsolationError, "cannot set transaction isolation in a nested transaction"
        end
        connection.create_savepoint(@savepoint_name = savepoint_name)
      end

      def rollback
        connection.rollback_to_savepoint(savepoint_name)
        super
        rollback_records
      end

      def commit
        connection.release_savepoint(savepoint_name)
        super
      end

      def full_rollback?; false; end
    end

    class RealTransaction < Transaction

      def initialize(connection, options)
        super
        if options[:isolation]
          connection.begin_isolated_db_transaction(options[:isolation])
        else
          connection.begin_db_transaction
        end
      end

      def rollback
        connection.rollback_db_transaction
        super
        rollback_records
      end

      def commit
        connection.commit_db_transaction
        super
      end
    end

    class TransactionManager #:nodoc:
      def initialize(connection)
        @stack = []
        @connection = connection
      end

      def begin_transaction(options = {})
        if options[:top_level]
          raise ":top_level option can't be set manually"
        end

        unless top_level or options[:skip_top_level]
          options[:top_level] = true
        end

        transaction =
          if @stack.empty?
            RealTransaction.new(@connection, options)
          else
            SavepointTransaction.new(@connection, "active_record_#{@stack.size}", options)
          end

        @stack.push(transaction)
        transaction
      end

      def top_level
        @stack.detect(&:top_level?)
      end

      def commit_transaction
        inner_transaction = @stack.pop
        inner_transaction.commit

        if inner_transaction.top_level?
          inner_transaction.commit_records
        else
          inner_transaction.records.each do |r|
            current_transaction.add_record(r)
          end
        end
      end

      def rollback_transaction
        @stack.pop.rollback
      end

      def within_new_transaction(options = {})
        transaction = begin_transaction options
        yield
      rescue Exception => error
        rollback_transaction if transaction
        raise
      ensure
        unless error
          if Thread.current.status == 'aborting'
            rollback_transaction
          else
            begin
              commit_transaction
            rescue Exception
              transaction.rollback unless transaction.state.completed?
              raise
            end
          end
        end
      end

      def open_transactions
        @stack.size
      end

      def current_transaction
        @stack.last || NULL_TRANSACTION
      end

      private
        NULL_TRANSACTION = NullTransaction.new
    end
  end
end
