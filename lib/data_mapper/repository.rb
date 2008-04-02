require 'uri'
require __DIR__ + 'support/errors'
require __DIR__ + 'logger'
require __DIR__ + 'adapters/abstract_adapter'
require __DIR__ + 'identity_map'
require __DIR__ + 'naming_conventions'

# Delegates to DataMapper::repository.
# Will not overwrite if a method of the same name is pre-defined.
module Kernel
  def repository(name = :default)
    unless block_given?
      begin
        DataMapper::Repository.context.last || DataMapper::Repository.new(name)
      #rescue NoMethodError
       # raise RepositoryNotSetupError.new("#{name.inspect} repository not set up.")
      end
    else
      begin
        return yield(DataMapper::Repository.context.push(DataMapper::Repository.new(name)))
      ensure
        # current = DataMapper::Repository.context.last
        # current.flush! if current.adapter.auto_flush?
        DataMapper::Repository.context.pop
      end
    end
  end
end

module DataMapper

  def self.setup(name, uri, options = {})
    uri = uri.is_a?(String) ? URI.parse(uri) : uri

    raise ArgumentError.new("'name' must be a Symbol") unless name.is_a?(Symbol)
    raise ArgumentError.new("'uri' must be a URI or String") unless uri.is_a?(URI)

    unless Adapters::const_defined?(DataMapper::Inflection.classify(uri.scheme) + "Adapter")
      begin
        require __DIR__ + "adapters/#{DataMapper::Inflection.underscore(uri.scheme)}_adapter"
      rescue LoadError
        require "#{DataMapper::Inflection.underscore(uri.scheme)}_adapter"
      end
    end

    adapter = Adapters::const_get(DataMapper::Inflection.classify(uri.scheme) + "Adapter").new(name, uri)

    Repository.adapters[name] = adapter
  end

  # ===Block Syntax:
  # Pushes the named repository onto the context-stack,
  # yields a new session, and pops the context-stack.
  #
  #   results = DataMapper.repository(:second_database) do |current_context|
  #     ...
  #   end
  #
  # ===Non-Block Syntax:
  # Returns the current session, or if there is none,
  # a new Session.
  #
  #   current_repository = DataMapper.repository
  def self.repository(name = :default) # :yields: current_context
    unless block_given?
      begin
        Repository.context.last || Repository.new(name)
      #rescue NoMethodError
       # raise RepositoryNotSetupError.new("#{name.inspect} repository not set up.")
      end
    else
      begin
        return yield(Repository.context.push(Repository.new(name)))
      ensure
        Repository.context.pop
      end
    end
  end

  class Repository

    @adapters = {}

    def self.adapters
      @adapters
    end

    def self.context
      Thread::current[:repository_contexts] || Thread::current[:repository_contexts] = []
    end

    attr_reader :name, :adapter

    def initialize(name)
      @name = name
      @adapter = self.class.adapters[name]
      @identity_map = IdentityMap.new
    end

    def identity_map_get(resource, key)
      @identity_map.get(resource, key)
    end

    def identity_map_set(instance)
      @identity_map.set(instance)
    end

    def get(resource, key)
      @identity_map.get(resource, key) || @adapter.read(self, resource, key)
    end

    def first(resource, options)
      @adapter.read_one(self, Query.new(resource, options))
    end

    def all(resource, options)
      @adapter.read_set(self, Query.new(resource, options))
    end

    def fake_it(resource)
      @adapter.fake_it(self, resource)
    end

    def save(instance)
      instance.child_associations.each { |a| a.save }

      success = if instance.new_record?
        if @adapter.create(self, instance)
          @identity_map.set(instance)
          instance.instance_variable_set('@new_record', false)
          instance.dirty_attributes.clear
          true
        else
          false
        end
      else
        if @adapter.update(self, instance)
          instance.dirty_attributes.clear
          true
        else
          false
        end
      end

      instance.parent_associations.each { |a| a.save }
      success
    end

    def destroy(instance)
      if @adapter.delete(self, instance)
        @identity_map.delete(instance.class, instance.key)
        instance.instance_variable_set('@new_record', true)
        instance.dirty_attributes.clear
        instance.class.properties(name).map do |property|
          instance.dirty_attributes << property if instance.attribute_loaded?(property.name)
        end
        true
      else
        false
      end
    end

  end

end
