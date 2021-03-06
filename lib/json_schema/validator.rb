require "uri"

module JsonSchema
  class Validator
    TYPE_MAP = {
      "array"   => Array,
      "boolean" => [FalseClass, TrueClass],
      "integer" => Integer,
      "number"  => [Integer, Float],
      "null"    => NilClass,
      "object"  => Hash,
      "string"  => String,
    }

    attr_accessor :errors

    def initialize(schema)
      @schema = schema
    end

    def validate(data)
      @errors = []
      @visits = {}
      validate_data(@schema, data, @errors, ['#'])
      @errors.size == 0
    end

    def validate!(data)
      if !validate(data)
        raise SchemaError.aggregate(@errors).join(" ")
      end
    end

    private

    def first_visit(schema, errors, path)
      path = path.join("/")
      pointer = schema.pointer
      if !@visits.key?(pointer) || !@visits[pointer].key?(path)
        @visits[pointer] ||= {}
        @visits[pointer][path] = true
        true
      else
        message = %{Validation loop detected.}
        errors << ValidationError.new(schema, path, message)
        false
      end
    end

    # for use with additionalProperties and strictProperties
    def get_extra_keys(schema, data)
      extra = data.keys - schema.properties.keys

      if schema.pattern_properties
        schema.pattern_properties.keys.each do |pattern|
          extra -= extra.select { |k| k =~ pattern }
        end
      end

      extra
    end

    # works around &&'s "lazy" behavior
    def strict_and(valid_old, valid_new)
      valid_old && valid_new
    end

    def validate_data(schema, data, errors, path)
      valid = true

      # detect a validation loop
      if !first_visit(schema, errors, path)
        return false
      end

      # validation: any
      valid = strict_and valid, validate_all_of(schema, data, errors, path)
      valid = strict_and valid, validate_any_of(schema, data, errors, path)
      valid = strict_and valid, validate_enum(schema, data, errors, path)
      valid = strict_and valid, validate_one_of(schema, data, errors, path)
      valid = strict_and valid, validate_not(schema, data, errors, path)
      valid = strict_and valid, validate_type(schema, data, errors, path)

      # validation: array
      if data.is_a?(Array)
        valid = strict_and valid, validate_items(schema, data, errors, path)
        valid = strict_and valid, validate_max_items(schema, data, errors, path)
        valid = strict_and valid, validate_min_items(schema, data, errors, path)
        valid = strict_and valid, validate_unique_items(schema, data, errors, path)
      end

      # validation: integer/number
      if data.is_a?(Float) || data.is_a?(Integer)
        valid = strict_and valid, validate_max(schema, data, errors, path)
        valid = strict_and valid, validate_min(schema, data, errors, path)
        valid = strict_and valid, validate_multiple_of(schema, data, errors, path)
      end

      # validation: object
      if data.is_a?(Hash)
        valid = strict_and valid, validate_additional_properties(schema, data, errors, path)
        valid = strict_and valid, validate_dependencies(schema, data, errors, path)
        valid = strict_and valid, validate_max_properties(schema, data, errors, path)
        valid = strict_and valid, validate_min_properties(schema, data, errors, path)
        valid = strict_and valid, validate_pattern_properties(schema, data, errors, path)
        valid = strict_and valid, validate_properties(schema, data, errors, path)
        valid = strict_and valid, validate_required(schema, data, errors, path, schema.required)
        valid = strict_and valid, validate_strict_properties(schema, data, errors, path)
      end

      # validation: string
      if data.is_a?(String)
        valid = strict_and valid, validate_format(schema, data, errors, path)
        valid = strict_and valid, validate_max_length(schema, data, errors, path)
        valid = strict_and valid, validate_min_length(schema, data, errors, path)
        valid = strict_and valid, validate_pattern(schema, data, errors, path)
      end

      valid
    end

    def validate_additional_properties(schema, data, errors, path)
      return true if schema.additional_properties == true

      # schema indicates that all properties not in `properties` should be
      # validated according to subschema
      if schema.additional_properties.is_a?(Schema)
        extra = get_extra_keys(schema, data)
        extra.each do |key|
          validate_data(schema.additional_properties, data[key], errors, path + [key])
        end
      # boolean indicates whether additional properties are allowed
      else
        validate_extra(schema, data, errors, path)
      end
    end

    def validate_all_of(schema, data, errors, path)
      return true if schema.all_of.empty?
      valid = schema.all_of.all? do |subschema|
        validate_data(subschema, data, errors, path)
      end
      message = %{Data did not match all subschemas of "allOf" condition.}
      errors << ValidationError.new(schema, path, message) if !valid
      valid
    end

    def validate_any_of(schema, data, errors, path)
      return true if schema.any_of.empty?
      valid = schema.any_of.any? do |subschema|
        validate_data(subschema, data, [], path)
      end
      if !valid
        message = %{Data did not match any subschema of "anyOf" condition.}
        errors << ValidationError.new(schema, path, message)
      end
      valid
    end

    def validate_dependencies(schema, data, errors, path)
      return true if schema.dependencies.empty?
      schema.dependencies.each do |key, obj|
        # if the key is not present, the dependency is fulfilled by definition
        next unless data[key]
        if obj.is_a?(Schema)
          validate_data(obj, data, errors, path)
        else
          # if not a schema, value is an array of required fields
          validate_required(schema, data, errors, path, obj)
        end
      end
    end

    def validate_format(schema, data, errors, path)
      return true unless schema.format
      valid = case schema.format
      when "date-time"
        data =~ DATE_TIME_PATTERN
      when "email"
        data =~ EMAIL_PATTERN
      when "hostname"
        data =~ HOSTNAME_PATTERN
      when "ipv4"
        data =~ IPV4_PATTERN
      when "ipv6"
        data =~ IPV6_PATTERN
      when "regex"
        Regexp.new(data) rescue false
      when "uri"
        URI.parse(data) rescue false
      when "uuid"
        data =~ UUID_PATTERN
      end
      if valid
        true
      else
        message = %{Expected data to match "#{schema.format}" format, value was: #{data}.}
        errors << ValidationError.new(schema, path, message)
        false
      end
    end

    def validate_enum(schema, data, errors, path)
      return true unless schema.enum
      if schema.enum.include?(data)
        true
      else
        message = %{Expected data to be a member of enum #{schema.enum}, value was: #{data}.}
        errors << ValidationError.new(schema, path, message)
        false
      end
    end

    def validate_extra(schema, data, errors, path)
      extra = get_extra_keys(schema, data)
      if extra.empty?
        true
      else
        message = %{Extra keys in object: #{extra.sort.join(", ")}.}
        errors << ValidationError.new(schema, path, message)
        false
      end
    end

    def validate_items(schema, data, errors, path)
      return true unless schema.items
      if schema.items.is_a?(Array)
        if data.size < schema.items.count
          message = %{Expected array to have at least #{schema.items.count} item(s), had #{data.size} item(s).}
          errors << ValidationError.new(schema, path, message)
          false
        elsif data.size > schema.items.count && !schema.additional_items?
          message = %{Expected array to have no more than #{schema.items.count} item(s), had #{data.size} item(s).}
          errors << ValidationError.new(schema, path, message)
          false
        else
          valid = true
          schema.items.each_with_index do |subschema, i|
            valid = strict_and valid,
              validate_data(subschema, data[i], errors, path + [i])
          end
          valid
        end
      else
        valid = true
        data.each_with_index do |value, i|
          valid = strict_and valid,
            validate_data(schema.items, value, errors, path + [i])
        end
        valid
      end
    end

    def validate_max(schema, data, errors, path)
      return true unless schema.max
      if schema.max_exclusive? && data < schema.max
        true
      elsif !schema.max_exclusive? && data <= schema.max
        true
      else
        message = %{Expected data to be smaller than maximum #{schema.max} (exclusive: #{schema.max_exclusive?}), value was: #{data}.}
        errors << ValidationError.new(schema, path, message)
        false
      end
    end

    def validate_max_items(schema, data, errors, path)
      return true unless schema.max_items
      if data.size <= schema.max_items
        true
      else
        message = %{Expected array to have no more than #{schema.max_items} item(s), had #{data.size} item(s).}
        errors << ValidationError.new(schema, path, message)
        false
      end
    end

    def validate_max_length(schema, data, errors, path)
      return true unless schema.max_length
      if data.length <= schema.max_length
        true
      else
        message = %{Expected string to have a maximum length of #{schema.max_length}, was #{data.length} character(s) long.}
        errors << ValidationError.new(schema, path, message)
        false
      end
    end

    def validate_max_properties(schema, data, errors, path)
      return true unless schema.max_properties
      if data.keys.size <= schema.max_properties
        true
      else
        message = %{Expected object to have a maximum of #{schema.max_properties} property/ies; it had #{data.keys.size}.}
        errors << ValidationError.new(schema, path, message)
        false
      end
    end

    def validate_min(schema, data, errors, path)
      return true unless schema.min
      if schema.min_exclusive? && data > schema.min
        true
      elsif !schema.min_exclusive? && data >= schema.min
        true
      else
        message = %{Expected data to be larger than minimum #{schema.min} (exclusive: #{schema.min_exclusive?}), value was: #{data}.}
        errors << ValidationError.new(schema, path, message)
        false
      end
    end

    def validate_min_items(schema, data, errors, path)
      return true unless schema.min_items
      if data.size >= schema.min_items
        true
      else
        message = %{Expected array to have at least #{schema.min_items} item(s), had #{data.size} item(s).}
        errors << ValidationError.new(schema, path, message)
        false
      end
    end

    def validate_min_length(schema, data, errors, path)
      return true unless schema.min_length
      if data.length >= schema.min_length
        true
      else
        message = %{Expected string to have a minimum length of #{schema.min_length}, was #{data.length} character(s) long.}
        errors << ValidationError.new(schema, path, message)
        false
      end
    end

    def validate_min_properties(schema, data, errors, path)
      return true unless schema.min_properties
      if data.keys.size >= schema.min_properties
        true
      else
        message = %{Expected object to have a minimum of #{schema.min_properties} property/ies; it had #{data.keys.size}.}
        errors << ValidationError.new(schema, path, message)
        false
      end
    end

    def validate_multiple_of(schema, data, errors, path)
      return true unless schema.multiple_of
      if data % schema.multiple_of == 0
        true
      else
        message = %{Expected data to be a multiple of #{schema.multiple_of}, value was: #{data}.}
        errors << ValidationError.new(schema, path, message)
        false
      end
    end

    def validate_one_of(schema, data, errors, path)
      return true if schema.one_of.empty?
      num_valid = schema.one_of.count do |subschema|
        validate_data(subschema, data, [], path)
      end
      if num_valid != 1
        message = %{Data did not match exactly one subschema of "oneOf" condition.}
        errors << ValidationError.new(schema, path, message)
      end
      num_valid == 1
    end

    def validate_not(schema, data, errors, path)
      return true unless schema.not
      # don't bother accumulating these errors, they'll all be worded
      # incorrectly for the inverse condition
      valid = !validate_data(schema.not, data, [], path)
      if !valid
        message = %{Data matched subschema of "not" condition.}
        errors << ValidationError.new(schema, path, message)
      end
      valid
    end

    def validate_pattern(schema, data, errors, path)
      return true unless schema.pattern
      if data =~ schema.pattern
        true
      else
        message = %{Expected string to match pattern "#{schema.pattern.inspect}", value was: #{data}.}
        errors << ValidationError.new(schema, path, message)
        false
      end
    end

    def validate_pattern_properties(schema, data, errors, path)
      return true if schema.pattern_properties.empty?
      valid = true
      schema.pattern_properties.each do |pattern, subschema|
        data.each do |key, value|
          if key =~ pattern
            valid = strict_and valid,
              validate_data(subschema, value, errors, path + [key])
          end
        end
      end
      valid
    end

    def validate_properties(schema, data, errors, path)
      return true if schema.properties.empty?
      valid = true
      schema.properties.each do |key, subschema|
        if data.key?(key)
          valid = strict_and valid,
            validate_data(subschema, data[key], errors, path + [key])
        end
      end
      valid
    end

    def validate_required(schema, data, errors, path, required)
      return true if !required || required.empty?
      if (missing = required - data.keys).empty?
        true
      else
        message = %{Missing required keys "#{missing.sort.join(", ")}" in object; keys are "#{data.keys.sort.join(", ")}".}
        errors << ValidationError.new(schema, path, message)
        false
      end
    end

    def validate_strict_properties(schema, data, errors, path)
      return true if !schema.strict_properties

      strict_and validate_extra(schema, data, errors, path),
        validate_required(schema, data, errors, path, schema.properties.keys)
    end

    def validate_type(schema, data, errors, path)
      return true if schema.type.empty?
      valid_types = schema.type.map { |t| TYPE_MAP[t] }.flatten.compact
      if valid_types.any? { |t| data.is_a?(t) }
        true
      else
        message = %{Expected data to be of type "#{schema.type.join("/")}"; value was: #{data.inspect}.}
        errors << ValidationError.new(schema, path, message)
        false
      end
    end

    def validate_unique_items(schema, data, errors, path)
      return true unless schema.unique_items?
      if data.size == data.uniq.size
        true
      else
        message = %{Expected array items to be unique, but duplicate items were found.}
        errors << ValidationError.new(schema, path, message)
        false
      end
    end

    EMAIL_PATTERN = /^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,4}$/i

    HOSTNAME_PATTERN = /^(?=.{1,255}$)[0-9A-Za-z](?:(?:[0-9A-Za-z]|-){0,61}[0-9A-Za-z])?(?:\.[0-9A-Za-z](?:(?:[0-9A-Za-z]|-){0,61}[0-9A-Za-z])?)*\.?$/

    DATE_TIME_PATTERN = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-2][0-9]:[0-5][0-9]:[0-5][0-9](Z|[\-+][0-9]{2}:[0-5][0-9])$/

    # from: http://stackoverflow.com/a/17871737
    IPV4_PATTERN = /^((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])$/

    # from: http://stackoverflow.com/a/17871737
    IPV6_PATTERN = /^(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]).){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:)$/

    UUID_PATTERN = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/
  end
end
