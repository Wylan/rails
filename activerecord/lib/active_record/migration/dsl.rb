# TODO: I need to add connection method but deprecate it so people have chance
# to update it's code to use, e.g., execute method
class ActiveRecord::Migration::DSL
  def self.api
    Methods::ALL # + %i[ revert reversible run ]
  end

  module Methods
    module WithoutTable
      ALL = %i[ execute enable_extension disable_extension ]
      # HACKAROUND
      ALL.concat %i[ revert reversible run ]
      ALL << :supports_foreign_keys? # should pass-through in revertible mode

      ALL.each do |name|
        define_method name do |*args, &block|
          connection.send name, *args, &block
        end
      end
    end

    module WithTable
      ALL = %i[
        create_table        drop_table           rename_table
        create_join_table   drop_join_table
        add_column          remove_column        rename_column
        add_index           remove_index         rename_index
        add_reference       remove_reference
        add_belongs_to      remove_belongs_to
        add_foreign_key     remove_foreign_key
        add_timestamps      remove_timestamps
        change_column       change_column_null   change_column_default
        change_table        remove_columns
      ]

      ALL.each do |name|
        define_method name do |table, *args, &block|
          connection.send name, proper_table_name(table), *args, &block
        end
      end
    end

    module WithSecondTable
      ALL = %i[ rename_table add_foreign_key remove_foreign_key ]

      ALL.each do |name|
        define_method name do |*args, &block|
          # second table name can be optional (as in #remove_foreign_key)
          unless args[1].is_a? Hash
            args[1] = proper_table_name args[1]
          end

          super(*args, &block)
        end
      end
    end

    ALL = WithoutTable::ALL + WithTable::ALL
    include WithoutTable, WithSecondTable, WithTable
  end

  include Methods
  attr_reader :config, :connection

  class RevertibleConnection < Delegator
    class ReversibleBlockHelper < Struct.new(:reverting) # :nodoc:
      def up
        yield unless reverting
      end

      def down
        yield if reverting
      end
    end

    def initialize
      @recorder = nil
    end

    def __setobj__(value)
    end

    def reversible
      helper = ReversibleBlockHelper.new !!@recorder
      execute_block { yield helper }
    end

    def execute_block
      @recorder ? super : yield
    end

    def revert(*migration_classes)
      if block_given?
        return super if @recorder
        begin
          # CommandRecorder should not proxy connection, it should just record all commands
          # otherwise some commands are executed immediately and some later
          @recorder = recorder = ActiveRecord::Migration::CommandRecorder.new __getobj__
          super
        ensure
          @recorder = nil
        end
        recorder.commands.each do |cmd, args, block|
          send(cmd, *args, &block)
        end
      else
        run(*migration_classes.reverse, direction: :down)
      end
    end

    def run(*migration_classes, direction: :up)
      # return super if @recorder - is needed to improve replay
      # so run will be ran when is appropriate by commandrecorder
      # but commandrecorder need to learn about run method as well
      if @recorder and @recorder.reverting
        direction = direction == :up ? :down : :up
      end
      migration_classes.each do |migration_class|
        migration_class.new.exec_migration(direction)
      end
    end

    def __getobj__
      @recorder || ActiveRecord::Base.connection
    end
  end

  # LoggableConnection.new connection
  def initialize(config = ActiveRecord::Base)
    @connection = RevertibleConnection.new
    @config     = config
  end

  private

  def proper_table_name(name)
    if name.respond_to? :table_name
      name.table_name
    else
      "#{config.table_name_prefix}#{name}#{config.table_name_suffix}"
    end
  end
end
