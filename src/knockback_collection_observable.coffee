###
  knockback_collection_observable.js
  (c) 2011 Kevin Malakoff.
  Knockback.CollectionObservable is freely distributable under the MIT license.
  See the following for full license details:
    https://github.com/kmalakoff/knockback/blob/master/LICENSE
###
throw new Error('Knockback: Dependency alert! knockback_core.js must be included before this file') if not this.Knockback

####################################################
# options
#   sortedIndex: (models, model) -> return add_index. Optional hook for sorting a model.
#     Default: the model's index in the collection is used.
#   sort_attribute: attribute_name. An optimization to check if a specific attribute has changed.
#     Default: resort on all changes to a model.
#
# Optional: If you wish to create view models, you must supply a target observable array and this option:
#   view_model: view_model_class
# With view models, the following are triggered the following Backbone.Events
#   add: (view_model, view_models_array) or if batch: (view_models_array)
#   resort: (view_model, view_models_array, new_index) or if batch: (view_models_array)
#   remove: (view_model, view_models_array) or if batch: (view_models_array)
####################################################

class Knockback.CollectionObservable
  constructor: (collection, @vm_observable_array, @options={}) ->
    throw new Error('CollectionObservable: collection is missing') if not collection
    if @vm_observable_array or @options.view_model
      throw new Error('CollectionObservable: vm_observable_array is missing') if not @vm_observable_array
      throw new Error('CollectionObservable: options is missing') if not @options
      throw new Error('CollectionObservable: options.view_model is missing') if not @options.view_model

    _.bindAll(this, 'destroy', 'collection', 'sorting', 'viewModelByModel', 'eachViewModel', 'bind', 'unbind', 'trigger')
    _.bindAll(this, '_onGetValue', '_onCollectionReset', '_onCollectionResort', '_onModelAdd', '_onModelRemove', '_onModelChanged')
    @_kb_collection = collection
    @_kb_collection.retain() if @_kb_collection.retain
    @_kb_collection.bind('reset', @_onCollectionReset)
    @_kb_collection.bind('resort', @_onCollectionResort) if not @options.sortedIndex
    @_kb_collection.bind(event, @_onModelAdd) for event in ['new', 'add']
    @_kb_collection.bind(event, @_onModelRemove) for event in ['remove', 'destroy']
    @_kb_collection.bind('change', @_onModelChanged)

    # internal state
    @_kb_value_observable = ko.observableArray([])

    @_kb_observable = ko.dependentObservable(@_onGetValue)

    # publish public interface on the observable and return instead of this
    @_kb_observable.destroy = @destroy
    @_kb_observable.collection = @collection
    @_kb_observable.viewModelByModel = @viewModelByModel
    @_kb_observable.eachViewModel = @eachViewModel
    @_kb_observable.sorting = @sorting
    # Backbone.Event interface
    @_kb_observable.bind = @bind
    @_kb_observable.unbind = @unbind
    @_kb_observable.trigger = @trigger

    # start
    @_collectionResync()

    return kb.wrappedObservable(this)

  destroy: ->
    @_kb_collection.unbind('reset', @_onCollectionReset)
    @_kb_collection.unbind('resort', @_onCollectionResort) if not @options.sortedIndex
    @_kb_collection.unbind(event, @_onModelAdd) for event in ['new', 'add']
    @_kb_collection.unbind(event, @_onModelRemove) for event in ['remove', 'destroy']
    @_kb_collection.unbind('change', @_onModelChanged)
    @_kb_collection.release() if @_kb_collection.release; @_kb_collection = null
    @_kb_value_observable = null
    @_kb_observable.dispose(); @_kb_observable = null
    @vm_observable_array = null
    @options = null

  collection: ->
    @_kb_value_observable() # force a dependency
    return @_kb_collection

  sorting: (sortedIndex, sort_attribute) ->
    return {sortedIndex: @options.sortedIndex, sort_attribute: @options.sort_attribute} if arguments.length == 0
    @options.sort_attribute = sort_attribute
    @options.sortedIndex = sortedIndex
    @_collectionResync(true) # resort everything (TODO: do it incrementally with a notification for resort if not too complex)
    @trigger('resort', @vm_observable_array()) # notify

  viewModelByModel: (model) ->
    throw new Error("CollectionObservable: cannot get a view model if vm_observable_array was not supplied") if not @vm_observable_array
    id_attribute = if model.hasOwnProperty(model.idAttribute) then model.idAttribute else 'cid'
    return _.find(@vm_observable_array(), (test) -> return (test.__kb_model[id_attribute] == model[id_attribute]))

  eachViewModel: (iterator) -> iterator(view_model) for view_model in @vm_observable_array()

  ####################################################
  # Internal
  ####################################################
  _onGetValue: -> return @_kb_value_observable()
  _onCollectionReset: -> @_collectionResync()

  _onCollectionResort: (model_or_models) ->
    throw new Error("CollectionObservable: collection sorting unexpected") if @options.sortedIndex
    if _.isArray(model_or_models)
      @_collectionResync(true) # TODO optimized with incremental resorting
      @trigger('resort', @vm_observable_array()) # notify
    else
      @_onModelResort(model_or_models)

  _onModelAdd: (model) ->
    if @options.sortedIndex
      sorted_models = _.pluck(@vm_observable_array(), '__kb_model')
      add_index = @options.sortedIndex(sorted_models, model)
    else
      add_index = @_kb_collection.indexOf(model)

    if @vm_observable_array
      view_model = @_viewModelCreate(model)
      @vm_observable_array.splice(add_index, 0, view_model)
    @_kb_value_observable.splice(add_index, 0, model)

    if @vm_observable_array
      @trigger('add', view_model, @vm_observable_array()) # notify

  _onModelRemove: (model) ->
    @_kb_value_observable.remove(model)

    if @vm_observable_array
      view_model = @viewModelByModel(model)
      return if not view_model # both the model and collection notify of destroy so may already have been removed
      @vm_observable_array.remove(view_model)

      @trigger('remove', view_model, @vm_observable_array()) # notify

      kb.vmDestroy(view_model)
      view_model.__kb_model = null

  _onModelChanged: (model) ->
    # sorting required
    if @options.sortedIndex and (not @options.sort_attribute or model.hasChanged(@options.sort_attribute))
      @_onModelResort(model)

  _onModelResort: (model) ->
    previous_index = @_kb_value_observable.indexOf(model)
    if @options.sortedIndex
      sorted_models = _.clone(@_kb_value_observable())
      sorted_models.splice(previous_index, 1)  # it is assumed that it is cheaper to copy the array during the test rather than redrawing the views multiple times if it didn't move
      new_index = @options.sortedIndex(sorted_models, model)
    else
      new_index = @_kb_collection.indexOf(model)
    return if previous_index == new_index # no change

    if @vm_observable_array
      view_model = @viewModelByModel(model)
      @vm_observable_array.splice(previous_index, 1); @vm_observable_array.splice(new_index, 0, view_model) # move

    @_kb_value_observable.splice(previous_index, 1); @_kb_value_observable.splice(new_index, 0, model) # move

    if @vm_observable_array
      @trigger('resort', view_model, @vm_observable_array(), new_index) # notify

  _collectionResync: (skip_notifications) ->
    if @vm_observable_array
      @trigger('remove', @vm_observable_array()) if not skip_notifications # notify
      view_models = @vm_observable_array.removeAll() # batch
      kb.vmDestroy(view_model) for view_model in view_models

    @_kb_value_observable.removeAll()

    if @options.sortedIndex
      models = []
      for model in @_kb_collection.models
        do (model) =>
          add_index = @options.sortedIndex(models, model)
          models.splice(add_index, 0, model)
    else
      models = _.clone(@_kb_collection.models)

    if @vm_observable_array
      view_models = []
      view_models.push(@_viewModelCreate(model)) for model in models
      @vm_observable_array(view_models) # batch

    @_kb_value_observable(models)

    if @vm_observable_array
      @trigger('add', @vm_observable_array()) if not skip_notifications # notify

  _viewModelCreate: (model) ->
    view_model = new @options.view_model(model)
    view_model.__kb_model = model
    return view_model

#######################################
# Mix in Backbone.Events so callers can subscribe
#######################################
Knockback.CollectionObservable.prototype extends Backbone.Events

# factory function
Knockback.collectionObservable = (collection, vm_observable_array, options) -> return new Knockback.CollectionObservable(collection, vm_observable_array, options)

# helpers
Knockback.viewModelGetModel = Knockback.vmModel = (view_model) -> view_model.__kb_model
