module JsonSchema
  class Schema
    @@copyable = []

    # identical to attr_accessible, but allows us to copy in values from a
    # target schema to help preserve our hierarchy during reference expansion
    def self.attr_copyable(attr)
      attr_accessor(attr)
      @@copyable << "@#{attr}".to_sym
    end

    # Rather than a normal schema, the node may be a JSON Reference. In this
    # case, no other attributes will be filled in except for #parent.
    attr_copyable :reference

    # the schema keeps a reference to the data it was initialized from for JSON
    # Pointer resolution
    attr_copyable :data

    # parent and children schemas
    attr_copyable :parent

    # the normalize URI of this schema
    attr_copyable :uri

    # basic descriptors
    attr_copyable :id
    attr_copyable :title
    attr_copyable :description
    attr_copyable :default

    # validation: any
    attr_copyable :all_of
    attr_copyable :any_of
    attr_copyable :definitions
    attr_copyable :enum
    attr_copyable :one_of
    attr_copyable :not
    attr_copyable :type

    # validation: array
    attr_copyable :additional_items
    attr_copyable :items
    attr_copyable :max_items
    attr_copyable :min_items
    attr_copyable :unique_items

    # validation: number/integer
    attr_copyable :max
    attr_copyable :max_exclusive
    attr_copyable :min
    attr_copyable :min_exclusive
    attr_copyable :multiple_of

    # validation: object
    attr_copyable :additional_properties
    attr_copyable :dependencies
    attr_copyable :max_properties
    attr_copyable :min_properties
    attr_copyable :pattern_properties
    attr_copyable :properties
    attr_copyable :required

    # validation: string
    attr_copyable :format
    attr_copyable :max_length
    attr_copyable :min_length
    attr_copyable :pattern

    # hyperschema
    attr_copyable :links
    attr_copyable :media
    attr_copyable :read_only
    attr_copyable :path_start

    # allow booleans to be access with question mark
    alias :additional_properties? :additional_properties
    alias :max_exclusive? :max_exclusive
    alias :min_exclusive? :min_exclusive
    alias :read_only? :read_only
    alias :unique_items? :unique_items

    def initialize
      @type = []

      # these are all the subschema types; default them to empty data
      # structures for simplified iteration
      @all_of = []
      @any_of = []
      @one_of = []
      @definitions = {}
      @dependencies = {}
      @pattern_properties = {}
      @properties = {}
    end

    def additional_items
      !@additional_items.nil? ? @additional_items : true
    end

    def additional_properties
      !@additional_properties.nil? ? @additional_properties : true
    end

    def max_exclusive
      !@max_exclusive.nil? ? @max_exclusive : false
    end

    def min_exclusive
      !@min_exclusive.nil? ? @min_exclusive : false
    end

    # child schemas of all types
    def children
      Enumerator.new do |yielder|
        all_of.each { |s| yielder << s }
        any_of.each { |s| yielder << s }
        one_of.each { |s| yielder << s }
        definitions.each { |_, s| yielder << s }
        pattern_properties.each { |_, s| yielder << s }
        properties.each { |_, s| yielder << s }

        if self.not
          yielder << self.not
        end

        # can either be a single schema (list validation) or multiple (tuple
        # validation)
        if items
          if items.is_a?(Array)
            items.each { |s| yielder << s }
          else
            yielder << items
          end
        end

        # dependencies can either be simple or "schema"; only replace the
        # latter
        dependencies.values.
          select { |s| s.is_a?(Schema) }.
          each { |s| yielder << s }
      end
    end

    def copy_from(schema)
      @@copyable.each do |copyable|
        instance_variable_set(copyable, schema.instance_variable_get(copyable))
      end
    end

    def expand_references!
      ReferenceExpander.new(self).expand!
      # return self for convenience
      self
    end

    def validate!(data)
      Validator.new(self).validate!(data)
    end
  end
end
