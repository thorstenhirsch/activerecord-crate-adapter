# -*- coding: utf-8; -*-
#
# Licensed to CRATE Technology GmbH ("Crate") under one or more contributor
# license agreements.  See the NOTICE file distributed with this work for
# additional information regarding copyright ownership.  Crate licenses
# this file to you under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.  You may
# obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
# License for the specific language governing permissions and limitations
# under the License.
#
# However, if you have executed another commercial license agreement
# with Crate these terms will supersede the license and you may use the
# software solely pursuant to the terms of the relevant commercial agreement.

require 'active_record'
require 'active_record/base'
require 'arel/arel_crate'
require 'active_record/connection_adapters/abstract_adapter'
require 'arel/visitors/bind_visitor'
require 'active_support/dependencies/autoload'
require 'active_support/callbacks'
require 'active_support/core_ext/string'
require 'active_record/connection_adapters/crate/type'
require 'active_record/connection_adapters/crate/type_metadata'
require 'active_record/connection_adapters/statement_pool'
require 'active_record/connection_adapters/column'
require 'active_record/connection_adapters/crate/schema_statements'
require 'active_record/connection_adapters/crate/database_statements'
require 'active_record/connection_adapters/crate/quoting'
require 'active_support/core_ext/kernel'

begin
  require 'crate_ruby'
rescue LoadError => e
  raise e
end

module ActiveRecord

  class Base
    def self.crate_connection(config) #:nodoc:
      config = config.symbolize_keys
      ConnectionAdapters::CrateAdapter.new(nil, logger, nil, config)
    end
  end

  module ConnectionAdapters
    class CrateAdapter < AbstractAdapter
      class ColumnDefinition < ActiveRecord::ConnectionAdapters::ColumnDefinition
        attr_accessor :array, :object
      end

      include Crate::SchemaStatements
      include DatabaseStatements
      include Crate::Quoting

      ADAPTER_NAME = 'Crate'.freeze

      def schema_creation # :nodoc:
        Crate::SchemaCreation.new self
      end

      NATIVE_DATABASE_TYPES = {
          boolean: {name: "boolean"},
          string: {name: "string"},
          integer: {name: "integer"},
          float: {name: "float"},
          binary: {name: "byte"},
          datetime: {name: "timestamp"},
          timestamp: {name: "timestamp"},
          object: {name: "object"},
          array: {name: "array"},
          ip: {name: "ip"},
      }



      class BindSubstitution < Arel::Visitors::Crate # :nodoc:
        include Arel::Visitors::BindVisitor
      end

      def initialize(connection, logger, pool, config={})
        @port = config[:port]
        @host = config[:host]
        super(connection, logger, config)
        @schema_cache = SchemaCache.new self
        @visitor = Arel::Visitors::Crate.new self
        @quoted_column_names = {}
        @type_map = Type::HashLookupTypeMap.new
        initialize_type_map(type_map)

        connect
      end


      def initialize_type_map(m)
        m.register_type 'string_array', Crate::Type::Array.new
        m.register_type 'integer_array', Crate::Type::Array.new
        m.register_type 'boolean_array', Crate::Type::Array.new
        m.register_type 'timestamp', Crate::Type::DateTime.new
      end

      def adapter_name
        ADAPTER_NAME
      end

      # Adds `:array` option to the default set provided by the
      # AbstractAdapter
      def prepare_column_options(column, types)
        spec = super
        spec[:array] = 'true' if column.respond_to?(:array) && column.array
        spec
      end

      # Adds `:array` as a valid migration key
      def migration_keys
        super + [:array, :object_schema_behaviour, :object_schema]
      end

      def arel_visitor
        Arel::Visitors::Crate.new self
      end


      #TODO check what call to use for active
      def active?
        true
      end

      #TODO
      def clear_cache!
      end

      #TODO
      def reset!
      end

      def supports_migrations?
        true
      end

      def connect
        @connection = CrateRuby::Client.new(["#{@host}:#{@port}"])
      end

      def columns(table_name) #:nodoc:
        cols = @connection.table_structure(table_name).map do |field|
          name = dotted_name(field[0])
          sql_type_metadata = fetch_type_metadata field[1]
          CrateColumn.new(name, nil, sql_type_metadata)
        end
        cols
      end


      def dotted_name(name)
        name.gsub(%r(\[['"]), '.').delete(%{'"]})
      end

      def tables
        @connection.tables
      end

      # def quote_column_name(name) #:nodoc:
      #   @quoted_column_names[name] ||= %Q{"#{name.to_s}"}
      # end

      class CrateColumn < Column

        def simplified_type(field_type)
          case field_type
            when /_array/i
              :array
            when /object/i
              :object
            else
              super(field_type)
          end
        end

      end

      class TableDefinition < ActiveRecord::ConnectionAdapters::TableDefinition

        # Crate doesn't support auto incrementing, therefore we need to manually
        # set a primary key. You need to assure that you always provide an unique
        # id. This might be done via the
        # +SecureRandom.uuid+ method and a +before_save+ callback, for instance.
        def primary_key(name, type = :primary_key, options = {})
          options[:primary_key] = true
          column name, "STRING PRIMARY KEY", options
        end

        def column(name, type = nil, options = {})
          super(name, type, options)
        end

        def object(name, options = {})
          schema_behaviour = options.delete(:object_schema_behaviour)
          type = schema_behaviour ? "object(#{schema_behaviour})" : schema_behaviour
          schema = options.delete(:object_schema)
          type = "#{type} as (#{object_schema_to_string(schema)})" if schema

          column name, type, options.merge(object: true)
        end

        def array(name, options = {})
          array_type = options.delete(:array_type)
          raise "Array columns must specify an :array_type (e.g. array_type: :string)" unless array_type.present?
          column name, "array(#{array_type})", options.merge(array: true)
        end

        def hstore(name, options = {})
          column name, "object(dynamic)", options
        end

        def ip(name, options={})
          column name, 'ip', options
        end
        alias_method :inet, :ip

        def references(name, options = {})
          options[:type] ||= :string
          super(name, options)
        end

        def new_column_definition(name, type, options)
          options = remove_unsupported_options(options)
          column = super(name, type, options)
          column.array = options[:array]
          column.object = options[:object]
          column
        end

        private

        def remove_unsupported_options(options = {})
          print_unsupported("null:false/true") && options.delete(:null) if options.has_key?(:null)
          print_unsupported("DEFAULT") && options.delete(:default) if options.has_key?(:default)
          options
        end

        def print_unsupported(option_name)
          puts
          puts "#########"
          puts "Option #{option_name} is currently not supported by Crate"
          puts "#########"
          puts
          true
        end

        def create_column_definition(name, type)
          ColumnDefinition.new name, type
        end

        def object_schema_to_string(s)
          ary = []
          s.each_pair do |k, v|
            if v.is_a?(Symbol)
              ary << "#{k} #{v}"
            elsif v.is_a?(Hash)
              a = "array(#{v[:array]})"
              ary << "#{k} #{a}"
            end
          end
          ary.join(', ')
        end


      end

       def create_table_definition(*args)
          TableDefinition.new(*args)
       end

      def native_database_types
        NATIVE_DATABASE_TYPES
      end

    end
  end


end
