module RailsDevelopmentBoost
  module DependenciesPatch
    def self.apply!
      patch = self
      ActiveSupport::Dependencies.module_eval do
        include patch
        remove_method :remove_unloadable_constants!
        alias_method_chain :load_file, 'constant_tracking'
        alias_method_chain :remove_constant, 'handling_of_connections'
        extend self
      end
    end
    
    mattr_accessor :module_cache
    self.module_cache = []
    
    mattr_accessor :file_map
    self.file_map = {}
    
    mattr_accessor :constants_being_removed
    self.constants_being_removed = []
    
    # Overridden.
    def remove_unloadable_constants!
      #autoloaded_constants.each { |const| remove_constant const }
      #autoloaded_constants.clear
      explicitly_unloadable_constants.each { |const| remove_constant const }
    end
    
    def unload_modified_files
      file_map.each_value do |file|
        file.constants.each { |const| remove_constant(const) } if file.changed?
      end
    end
    
    # Augmented `load_file'.
    def load_file_with_constant_tracking(path, *args, &block)
      result = load_file_without_constant_tracking(path, *args, &block)
      new_constants = autoloaded_constants - file_map.values.map(&:constants).flatten
      
      # Associate newly loaded constants to the file just loaded
      if new_constants.any?
        path_marked_loaded = path.sub('.rb', '')
        file_map[path_marked_loaded] ||= LoadedFile.new(path)
        file_map[path_marked_loaded].constants |= new_constants
      end

      return result
    end
    
    # Augmented `remove_constant'.
    def remove_constant_with_handling_of_connections(const_name)
      fetch_module_cache do
        prevent_further_removal_of(const_name) do
          object = const_name.constantize rescue nil
          handle_connected_constants(object, const_name) if object
          result = remove_constant_without_handling_of_connections(const_name)
          clear_tracks_of_removed_const(const_name)
          return result
        end
      end
    end
  
  private
    
    def handle_connected_constants(object, const_name)
      return unless Module === object && qualified_const_defined?(const_name)
      remove_dependent_modules(object)
      update_activerecord_related_references(object)
      autoloaded_constants.grep(/^#{const_name}::[^:]+$/).each { |const| remove_constant(const) }
    end
    
    def clear_tracks_of_removed_const(const_name)
      autoloaded_constants.delete(const_name)
      module_cache.delete_if { |mod| mod.name == const_name }
      file_map.each do |path, file|
        file.constants.delete(const_name)
        if file.constants.empty?
          loaded.delete(path)
          file_map.delete(path)
        end
      end
    end
    
    def remove_dependent_modules(mod)
      fetch_module_cache do |modules|
        modules.each do |other|
          next unless other < mod
          next unless other.superclass == mod if Class === mod
          next unless other.name.constantize == other
          remove_constant(other.name)
        end
      end
    end
    
    # egrep -ohR '@\w*([ck]lass|refl|target|own)\w*' activerecord | sort | uniq
    def update_activerecord_related_references(klass)
      return unless defined?(ActiveRecord)
      return unless klass < ActiveRecord::Base

      # Reset references held by macro reflections (klass is lazy loaded, so
      # setting its cache to nil will force the name to be resolved again).
      ActiveRecord::Base.instance_eval { subclasses }.each do |model|
        model.reflections.each_value do |reflection|
          reflection.instance_eval do
            @klass = nil if @klass == klass
          end
        end
      end

      # Update ActiveRecord's registry of its subclasses
      registry = ActiveRecord::Base.class_eval("@@subclasses")
      registry.delete(klass)
      (registry[klass.superclass] || []).delete(klass)
    end
  
  private

    def fetch_module_cache
      return(yield(module_cache)) if module_cache.any?
      
      ObjectSpace.each_object(Module) { |mod| module_cache << mod unless (mod.name || "").empty? }
      begin
        yield module_cache
      ensure
        module_cache.clear
      end
    end

    def prevent_further_removal_of(const_name)
      return if constants_being_removed.include?(const_name)
      
      constants_being_removed << const_name
      begin
        yield
      ensure
        constants_being_removed.delete(const_name)
      end
    end
  end
end