require "rubygems"
require "bundler/setup"
require "active_model"
require "erb"
require "rest-client"
require "json"
require "active_support/hash_with_indifferent_access"
require "query"
require "children"

module ParseResource

  class Base
    # ParseResource::Base provides an easy way to use Ruby to interace with a Parse.com backend
    # Usage:
    #  class Post < ParseResource::Base
    #    fields :title, :author, :body
    #  end

    include ActiveModel::Validations
    include ActiveModel::Conversion
    include ActiveModel::AttributeMethods
    extend ActiveModel::Naming
    extend ActiveModel::Callbacks
    HashWithIndifferentAccess = ActiveSupport::HashWithIndifferentAccess

    define_model_callbacks :save, :create, :update, :destroy
    
    # Instantiates a ParseResource::Base object
    #
    # @params [Hash], [Boolean] a `Hash` of attributes and a `Boolean` that should be false only if the object already exists
    # @return [ParseResource::Base] an object that subclasses `Parseresource::Base`
    def initialize(attributes = {}, new=true)
      attributes = HashWithIndifferentAccess.new(attributes)
      if new
        @unsaved_attributes = attributes
      else
        @unsaved_attributes = {}
      end
      self.attributes = {}
      self.attributes.merge!(attributes)
      self.attributes unless self.attributes.empty?
      create_setters!
    end

    # Explicitly adds a field to the model.
    #
    # @param [Symbol] name the name of the field, eg `:author`.
    # @param [Boolean] val the return value of the field. Only use this within the class.
    def self.field(name, val=nil)
      class_eval do
        define_method(name) do
          @attributes[name] ? @attributes[name] : @unsaved_attributes[name]
        end
        define_method("#{name}=") do |val|
          @attributes[name] = val
          @unsaved_attributes[name] = val
          val
        end
      end
    end

    # Add multiple fields in one line. Same as `#field`, but accepts multiple args.
    #
    # @param [Array] *args an array of `Symbol`s, `eg :author, :body, :title`.
    def self.fields(*args)
      args.each {|f| field(f)}
    end
  

    # Creates getter and setter methods for model fields
    # 
    def create_setters!
      @attributes.each_pair do |k,v|
        
        self.class.send(:define_method, "#{k}=") do |val|
          if k.is_a?(Symbol)
            k = k.to_s
          end
          @attributes[k.to_s] = val
          @unsaved_attributes[k.to_s] = val
          val
        end
        
        self.class.send(:define_method, "#{k}") do
          if k.is_a?(Symbol)
            k = k.to_s
          end

          if @attributes[k.to_s].is_a?(Hash)#["__type"]
            case @attributes[k.to_s]["__type"]
            when "Date"
              result = @attributes[k.to_s]["iso"]
            when "Pointer"
              klass_name = @attributes[k.to_s]["className"]
              klass_name = "User" if klass_name == "_User"
              
              klass = klass_name.constantize
              if @attributes[k.to_s].keys.include?("createdAt") #implies "include" was part of the query
                result = klass.new(@attributes, false)
                puts result.inspect
              else # since there was no "include", make a new query for the full object
                result = klass.find(@attributes[k.to_s]["objectId"])
              end
            end
          else
            result = @attributes[k.to_s]
          end

          return result
        end
      end
    end

    class << self
      
      def belongs_to(parent)
        parent_klass_name = parent.to_s.camelize
        
        send(:define_method, "#{parent}=") do |val|
          val.save unless val.id
          params = {
            "__type" => "Pointer",
            "className" => parent_klass_name,
            "objectId" => val.id
          }
          self.update(parent.to_s => params)
        end
        
        field parent

        nil
      end
      
      def has_many(children)
        parent_klass_name = model_name
        lowercase_parent_klass_name = parent_klass_name.downcase
        parent_klass = model_name.constantize
        child_klass_name = children.to_s.singularize.camelize
        child_klass = child_klass_name.constantize
        
        @@parent_klass_name = parent_klass_name
        
        if parent_klass_name == "User"
          parent_klass_name = "_User"
        end
        
        send(:define_method, children) do
          @@parent_id = self.id
          
          params = { lowercase_parent_klass_name => {
             "__type" => "Pointer", 
             "className" => parent_klass_name, 
             "objectId" => self.id
            }
          }
          
          singleton = child_klass.where(params).all
          
          class << singleton
            def <<(child)
              puts "from the singleton class. #{child.inspect}"
              child.save
              params = {
                "__type" => "Pointer", 
                "className" => @@parent_klass_name,
                "objectId" => @@parent_id
                }
              child.update(@@parent_klass_name.to_sym => params)
              super(child)
            end
          end
          
          singleton
        end
        
      end

      @@settings ||= nil

      # Explicitly set Parse.com API keys.
      #
      # @param [String] app_id the Application ID of your Parse database
      # @param [String] master_key the Master Key of your Parse database
      def load!(app_id, master_key)
        @@settings = {"app_id" => app_id, "master_key" => master_key}
      end

      def settings
        if @@settings.nil?
          path = "config/parse_resource.yml"
          #environment = defined?(Rails) && Rails.respond_to?(:env) ? Rails.env : ENV["RACK_ENV"]
          environment = ENV["RACK_ENV"]
          @@settings = YAML.load(ERB.new(File.new(path).read).result)[environment]
        end
        @@settings
      end

      # Creates a RESTful resource
      # sends requests to [base_uri]/[classname]
      #
      def resource
        if @@settings.nil?
          path = "config/parse_resource.yml"
          environment = defined?(Rails) && Rails.respond_to?(:env) ? Rails.env : ENV["RACK_ENV"]
          @@settings = YAML.load(ERB.new(File.new(path).read).result)[environment]
        end

        if model_name == "User" #https://parse.com/docs/rest#users-signup
          base_uri = "https://api.parse.com/1/users"
        else
          base_uri = "https://api.parse.com/1/classes/#{model_name}"
        end

        #refactor to settings['app_id'] etc
        app_id     = @@settings['app_id']
        master_key = @@settings['master_key']
        RestClient::Resource.new(base_uri, app_id, master_key)
      end

      # Find a ParseResource::Base object by ID
      #
      # @param [String] id the ID of the Parse object you want to find.
      # @return [ParseResource] an object that subclasses ParseResource.
      def find(id)
        where(:objectId => id).first
      end

      # Find a ParseResource::Base object by chaining #where method calls.
      #
      def where(*args)
        Query.new(self).where(*args)
      end
      
      # Include the attributes of a parent ojbect in the results
      # Similar to ActiveRecord eager loading
      #
      def include_object(parent)
        Query.new(self).include_object(parent)
      end

      # Add this at the end of a method chain to get the count of objects, instead of an Array of objects
      def count
        #https://www.parse.com/docs/rest#queries-counting
        Query.new(self).count(1)
      end

      # Find all ParseResource::Base objects for that model.
      #
      # @return [Array] an `Array` of objects that subclass `ParseResource`.
      def all
        Query.new(self).all
      end

      # Find the first object. Fairly random, not based on any specific condition.
      #
      def first
        Query.new(self).limit(1).first
      end

      # Limits the number of objects returned
      #
      def limit(n)
        Query.new(self).limit(n)
      end

      # Create a ParseResource::Base object.
      #
      # @param [Hash] attributes a `Hash` of attributes
      # @return [ParseResource] an object that subclasses `ParseResource`. Or returns `false` if object fails to save.
      def create(attributes = {})
        attributes = HashWithIndifferentAccess.new(attributes)
        new(attributes).save
      end

      def destroy_all
        all.each do |object|
          object.destroy
        end
      end

      def class_attributes
        @class_attributes ||= {}
      end

    end

    def persisted?
      if id
        true
      else
        false
      end
    end

    def new?
      !persisted?
    end

    # delegate from Class method
    def resource
      self.class.resource
    end

    # create RESTful resource for the specific Parse object
    # sends requests to [base_uri]/[classname]/[objectId]
    def instance_resource
      self.class.resource["#{self.id}"]
    end

    def create
      opts = {:content_type => "application/json"}
      attrs = @unsaved_attributes.to_json
      result = self.resource.post(attrs, opts) do |resp, req, res, &block|
        
        case resp.code 
        when 400
          
          # https://www.parse.com/docs/ios/api/Classes/PFConstants.html
          error = JSON.parse(resp)
          case error["code"]
          when 202
            self.errors.add(:username, "must be unique")
          when 111
            self.errors.add(:base, "field set to incorrect type. Error code #{error['code']}.")
          when 125
            self.errors.add(:email, "must be valid")
          when 122
            self.errors.add(:file_name, "contains only a-zA-Z0-9_. characters and is between 1 and 36 characters.")
          when 204
            self.errors.add(:email, "must not be missing")
          when 203
            self.errors.add(:email, "has already been taken")
          when 200
            self.errors.add(:username, "is missing or empty")
          when 201
            self.errors.add(:password, "is missing or empty")
          when 205
            self.errors.add(:user, "with specified email not found")
          else
            raise "Parse error #{error['code']}: #{error['error']}"
          end

        else
          @attributes.merge!(JSON.parse(resp))
          @attributes.merge!(@unsaved_attributes)
          attributes = HashWithIndifferentAccess.new(attributes)
          @unsaved_attributes = {}
          create_setters!
        end
        
        self
      end
    
      result
    end

    def save
      if valid?
        run_callbacks :save do
          new? ? create : update
        end
      else
        false
      end
      rescue false
    end

    def update(attributes = {})
      begin
        attributes = HashWithIndifferentAccess.new(attributes)
        @unsaved_attributes.merge!(attributes)

        put_attrs = @unsaved_attributes
        put_attrs.delete('objectId')
        put_attrs.delete('createdAt')
        put_attrs.delete('updatedAt')
        put_attrs = put_attrs.to_json

        resp = self.instance_resource.put(put_attrs, :content_type => "application/json")

        @attributes.merge!(JSON.parse(resp))
        @attributes.merge!(@unsaved_attributes)
        @unsaved_attributes = {}
        create_setters!

        self
      rescue
        self
      end
    end

    def update_attributes(attributes = {})
      self.update(attributes)
    end

    def destroy
      self.instance_resource.delete
      @attributes = {}
      @unsaved_attributes = {}
      nil
    end

    # provides access to @attributes for getting and setting
    def attributes
      @attributes ||= self.class.class_attributes
      @attributes
    end

    def attributes=(n)
      @attributes = n
      @attributes
    end

    # aliasing for idiomatic Ruby
    def id; self.objectId rescue nil; end

    def created_at; self.createdAt; end

    def updated_at; self.updatedAt rescue nil; end

    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
    end

  end
end
