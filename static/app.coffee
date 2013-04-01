require.onError = (err) -> console.error err

# Configure requirejs to load jQuery, Underscore, Backbone, and underscore
require.config
  paths:
    jquery: 'jquery-1.8.3'
    underscore:  'underscore/underscore'
    backbone:    'backbone/backbone'
    'socket-io': '/socket.io/socket.io'
  shim:
    underscore:
      exports: '_'
    backbone:
      deps: ['underscore', 'jquery']
      exports: 'Backbone'


define 'app', ['underscore', 'backbone', 'socket-io'], (_, Backbone, io) ->

  SOCKET = io.connect()

  # Factory for all Backbone Models and Collections
  # You will need to register a type for everything that
  # extends `Backbone.Model` or `Backbone.Collection`
  class AllBackbone
    CollectionModel = Backbone.Model.extend
      collection: null
      initialize: -> @id = @get('collection').url

    MODEL_CONSTRUCTORS = {}

    ALL_MODELS = new Backbone.Collection()
    ALL_COLLECTIONS = new Backbone.Collection()

    newModel: (constructorType, config, options) ->
      if config.toJSON
        throw 'YOU CREATED A MODEL THAT WE DONT KNOW ABOUT' if !ALL_MODELS.get(config.id)
      return ALL_MODELS.get config if ALL_MODELS.get config
      constructor = MODEL_CONSTRUCTORS[constructorType] or Backbone.Model
      model = new constructor config, {silent:true}
      ALL_MODELS.add model, {remote:true} # just so the collection does not propagate to the server
      SOCKET.emit 'MODEL', {name:'new', config:config, options:options, constructorType: constructorType}
      return model

    newCollection: (url, options) ->
      model = new Backbone.Collection()
      model.url = url
      grr = new CollectionModel {id:url, collection:model}, {remote:true}
      ALL_COLLECTIONS.add grr, {remote:true}
      if not options?.remote
        SOCKET.emit 'COLLECTION', {name:'new', url:url, options:options}
      return model

    getModel: (id) -> ALL_MODELS.get id
    getCollection: (url) ->
      modelContainer = ALL_COLLECTIONS.get(url)
      modelContainer.get 'collection'

    modelIds: -> ALL_MODELS.map (model) -> model.id
    collectionUrls: -> ALL_COLLECTIONS.map (model) -> model.id

    setModelConstructor: (typeName, constructor) ->
      MODEL_CONSTRUCTORS[typeName] = constructor

    # Useful for debugging views
    _modelsAsCollection: ALL_MODELS
    _collectionsAsCollection: ALL_COLLECTIONS

  @ALL_BACKBONE = new AllBackbone()


  FooModel = Backbone.Model.extend
    url: '/fooUrl'
    toJSON: -> {id: @id, foo: true}

  ALL_BACKBONE.setModelConstructor 'FooModel', FooModel

  # key->callbacks structure whenclient calls `Backbone.sync`
  syncWaiters = {}

  SOCKET.on 'STATE', (evt) ->
    for json in evt.models
      ALL_BACKBONE.newModel json.type, json, {silent:true, remote:true}

    # Populate all the Collections
    for url, models of evt.collections
      # Look up all the models
      models = (ALL_BACKBONE.getModel cfg.id for cfg in models)
      collection = ALL_BACKBONE.newCollection url, {remote:true}
      collection.set models, {silent:true, remote:true}

  SOCKET.on 'MODEL', (evt) ->
    switch evt.name
      when 'new' then ALL_BACKBONE.newModel evt.type, evt.config
      when 'change'
        model = ALL_BACKBONE.getModel evt.id
        throw "COULD NOT FIND MODEL WITH ID #{evt.id}" if not model

        model.set.call model, evt.changedAttributes, _.extend(evt.options, {remote:true})
      when 'sync'
        model = ALL_BACKBONE.getModel evt.id
        throw "COULD NOT FIND MODEL WITH ID #{evt.id}" if not model

        if syncWaiters[evt.id]
          options = syncWaiters[evt.id]
          # Mark that it came from the server (so it does not get sent back accidentally)
          #     options.remote = true
          delete syncWaiters[evt.id]

          switch evt.status
            when 'done' then options?.success?(evt.value, options)
            when 'fail' then options?.error?(evt.value, options)
            else throw 'INVALID STATUS FROM REMOTE Backbone.sync CALL'

      else throw "UNMATCHED EVENT #{evt.name}"


  SOCKET.on 'COLLECTION', (evt) ->
    switch evt.name
      when 'new' then ALL_BACKBONE.newCollection evt.url, {remote:true}
      when 'change'
        collection = ALL_BACKBONE.getCollection evt.url
        throw "COULD NOT FIND COLLECTION WITH URL #{evt.url}" if not collection

        models = _.map evt.models, (model) ->
          ALL_BACKBONE.getModel model.id
        collection.set models, _.extend(evt.options, {remote:true})
      else throw "UNMATCHED EVENT #{evt.name}"

  # Defer Sync events to the server
  Backbone.sync = (method, model, options) ->
    data =
      id: model.id
      name: 'sync'
      method: method
      options: options
    # Store the `success` and `error` callbacks when a response from the server arrives
    syncWaiters[model.id] = options

    SOCKET.emit 'MODEL', data

  Backbone.Model::_trigger = Backbone.Model::trigger
  Backbone.Model::trigger = (name, model) ->
    options = _.last arguments
    return @_trigger.apply @, arguments if options.remote

    args = _.rest arguments, 2

    changeCollection = ->
      [collection, options] = args
      data = {url: collection.url?() or collection.url or throw "COLLECTION MUST HAVE A URL"}
      # Send the state of the Collection
      data.name = 'change'
      data.models = collection.map (model) -> {id: model.id}
      data.options = options
      SOCKET.emit 'COLLECTION', data

    return @ if /^change:/.test name

    switch name
      when 'change'
        data = {id: model.id or throw 'MODELS MUST HAVE AN ID'}
        data.name = 'change'
        data.changedAttributes = model.changedAttributes()
        [data.options] = args
        SOCKET.emit 'MODEL', data

      # Adding to a Collection requires notifying the server of the collection URL
      when 'add' then changeCollection()
      when 'remove' then changeCollection()
      when 'reset' then changeCollection()
      when 'error'
        # Do not send to the server. Instead, log it
        console?.error 'LOCAL EVENT "error". Not sending to server'
      else throw "UNMATCHED EVENT #{name}"

    @_trigger.apply @, arguments

  ModelView = Backbone.View.extend
    template: (json) -> "<pre>#{JSON.stringify json}</pre>"
    initialize: ->
      @listenTo @model, 'change', => @render()

  AllModelsView = Backbone.View.extend
    template: (json) -> "<div><h2>All Models</h2>#{JSON.stringify json}</div>"

    initialize: ->
      @listenTo @collection, 'reset',   => @render()
      @listenTo @collection, 'add',     => @render()
      @listenTo @collection, 'remove',  => @render()


  CollectionModelView = Backbone.View.extend
    template: (model) -> "<pre>#{model.id}: #{model.collection.length} #{model.collection.map (model) -> model.id}</pre>"
    templateHelpers: -> return {collection: @model.get('collection').toJSON()}

    initialize: ->
      @listenTo @model.get('collection'), 'reset',   => @render()
      @listenTo @model.get('collection'), 'add',     => @render()
      @listenTo @model.get('collection'), 'remove',  => @render()
      @listenTo @model, 'change', => @render()

  AllCollectionsView = Backbone.View.extend
    template: (json) -> "<div><h2>All Collections</h2>#{JSON.stringify json}</div>"
    itemView: CollectionModelView

    initialize: ->
      @listenTo @collection, 'reset',   => @render()
      @listenTo @collection, 'add',     => @render()
      @listenTo @collection, 'remove',  => @render()


  view = new AllCollectionsView {collection: ALL_BACKBONE._collectionsAsCollection}
  $('body').prepend(view.render().$el)

  view = new AllModelsView {collection: ALL_BACKBONE._modelsAsCollection}
  $('body').prepend(view.render().$el)


  SOCKET.emit 'STATE?'
  @Collection = new Backbone.Collection()
  @Collection.url = '/foo/bar'

