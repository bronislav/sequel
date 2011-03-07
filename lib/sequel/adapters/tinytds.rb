require 'tiny_tds'
Sequel.require 'adapters/shared/mssql'

module Sequel
  module TinyTDS
    class Database < Sequel::Database
      include Sequel::MSSQL::DatabaseMethods
      set_adapter_scheme :tinytds
      
      # Transfer the :host and :user options to the
      # :dataserver and :username options.
      def connect(server)
        opts = server_opts(server)
        opts[:dataserver] = opts[:host]
        opts[:username] = opts[:user]
        TinyTds::Client.new(opts)
      end
      
      # Return instance of Sequel::TinyTDS::Dataset with the given options.
      def dataset(opts = nil)
        TinyTDS::Dataset.new(self, opts)
      end
    
      # Execute the given +sql+ on the server.  If the :return option
      # is present, its value should be a method symbol that is called
      # on the TinyTds::Result object returned from executing the
      # +sql+.  The value of such a method is returned to the caller.
      # Otherwise, if a block is given, it is yielded the result object.
      # If no block is given and a :return is not present, +nil+ is returned.
      def execute(sql, opts={})
        synchronize(opts[:server]) do |c|
          begin
            m = opts[:return]
            r = nil
            log_yield(sql) do
              r = c.execute(sql)
              return r.send(m) if m
            end
            yield(r) if block_given?
          rescue TinyTds::Error => e
            raise_error(e)
          ensure
           r.cancel if r && c.sqlsent?
          end
        end
      end

      # Return the number of rows modified by the given +sql+.
      def execute_dui(sql, opts={})
        execute(sql, opts.merge(:return=>:do))
      end

      # Return the value of the autogenerated primary key (if any)
      # for the row inserted by the given +sql+.
      def execute_insert(sql, opts={})
        execute(sql, opts.merge(:return=>:insert))
      end

      # Execute the DDL +sql+ on the database and return nil.
      def execute_ddl(sql, opts={})
        execute(sql, opts.merge(:return=>:each))
        nil
      end

      private

      # For some reason, unless you specify a column can be
      # NULL, it assumes NOT NULL, so turn NULL on by default unless
      # the column is a primary key column.
      def column_list_sql(g)
        pks = []
        g.constraints.each{|c| pks = c[:columns] if c[:type] == :primary_key} 
        g.columns.each{|c| c[:null] = true if !pks.include?(c[:name]) && !c[:primary_key] && !c.has_key?(:null) && !c.has_key?(:allow_null)}
        super
      end

      # Close the TinyTds::Client object.
      def disconnect_connection(c)
        c.close
      end
    end
    
    class Dataset < Sequel::Dataset
      include Sequel::MSSQL::DatasetMethods
      
      # Yield hashes with symbol keys, attempting to optimize for
      # various cases.
      def fetch_rows(sql)
        execute(sql) do |result|
          each_opts = {:cache_rows=>false}
          each_opts[:timezone] = :utc if Sequel.database_timezone == :utc
          offset = @opts[:offset]
          @columns = cols = result.fields.map{|c| output_identifier(c)}
          if identifier_output_method
            each_opts[:as] = :array
            result.each(each_opts) do |r|
              h = {}
              cols.zip(r).each{|k, v| h[k] = v}
              h.delete(row_number_column) if offset
              yield h
            end
          else
            each_opts[:symbolize_keys] = true
            if offset
              result.each(each_opts) do |r|
                r.delete(row_number_column) if offset
                yield r
              end
            else
              result.each(each_opts, &Proc.new)
            end
          end
        end
        self
      end
      
      private
      
      # Properly escape the given string +v+.
      def literal_string(v)
        db.synchronize{|c| "N'#{c.escape(v)}'"}
      end
    end
  end
end
