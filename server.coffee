# Set export objects for node and coffee to a function that generates a server.
module.exports = exports = (argv) ->
  # # Dependencies
  # anything not in the standard library is included in the repo, or
  # can be installed with an:
  #     npm install
  express     = require('express')
  path        = require('path')
  _           = require('underscore')
  Backbone    = require('backbone')

  # Create the main application object, app.
  app = express.createServer()
  io          = require('socket.io').listen app


  # bodyParser in connect 2.x uses node-formidable to parse
  # the multipart form data.
  # Used for getting Zips deposited via POST
  app.use(express.bodyParser())


  # ## Express configuration
  # Set up all the standard express server options,
  # including hbs to use handlebars/mustache templates
  # saved with a .html extension, and no layout.
  app.configure( ->
    app.set('view options', layout: false)
    app.use(express.cookieParser())
    app.use(express.bodyParser())
    app.use(express.methodOverride())
    app.use(express.session({ secret: 'notsecret'}))
    app.use(app.router)
    # Load static files from node_modules (bootstrap, jquery, Aloha, ...)
    app.use(express.static(path.join(__dirname, '..', 'lib')))
    app.use(express.static(path.join(__dirname, '..', 'node_modules')))
    app.use(express.static(path.join(__dirname, '..', 'static')))
  )


  # ### Routes
  # Routes currently make up the bulk of the Express
  # server. Most routes use literal names,
  # or regexes to match, and then access req.params directly.

  # ## Admin Page
  app.get('/', (req, res) ->
    #res.render('admin.html', {}) # {} is vars
    res.redirect('index.html')
  )



  jQuery = require 'jquery-deferred'
  najax = require 'najax'
  jQuery.ajax = najax
  Backbone.$ = jQuery

  # Convenience variable so the client and server share the same code
  SOCKET = io.sockets

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

    newModel: (type, config, options) ->
      if config.toJSON
        throw 'YOU CREATED A MODEL THAT WE DONT KNOW ABOUT' if !ALL_MODELS.get(config.id)
      return ALL_MODELS.get config if ALL_MODELS.get config
      constructor = MODEL_CONSTRUCTORS[type] or Backbone.Model
      model = new constructor config, {silent:true}
      ALL_MODELS.add model, {remote:true} # just so the collection does not propagate to the server
      SOCKET.emit 'MODEL', {name:'new', config:config, options:options}
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

  ALL_BACKBONE = new AllBackbone()

  # Add some dummy models and Collections
  ALL_BACKBONE.newModel null, {id: 'id123', hello: 'world', counter: 0}
  ALL_BACKBONE.newModel null, {id: 'id456', howdy: 'there', counter: 0}

  ALL_BACKBONE.newCollection '/foo/bar'
  ALL_BACKBONE.newCollection '/foo/baz'


  FooModel = Backbone.Model.extend
    url: -> 'http://localhost/fooUrl'
    toJSON: -> {id: @id, foo: true}

  ALL_BACKBONE.setModelConstructor 'FooModel', FooModel
  ALL_BACKBONE.newModel 'FooModel', {id: 'id789', about: 'This should be a FooModel'}


  io.sockets.on 'connection', (socket) ->
    # Send the current state of all models

    socket.on 'STATE?', (timestamp) ->
      collections = {}
      _.each ALL_BACKBONE.collectionUrls(), (url) -> collections[url] = ALL_BACKBONE.getCollection url
      socket.emit 'STATE', {models: ALL_BACKBONE._modelsAsCollection, collections: collections}

    socket.on 'MODEL', (evt) ->
      console.log 'RECEIVED MODEL', evt
      switch evt.name
        when 'new'
          model = ALL_BACKBONE.newModel evt.constructorType, evt.config, evt.options
        when 'change'
          model = ALL_BACKBONE.getModel evt.id
          model.set evt.changedAttributes
          SOCKET.emit 'MODEL', evt
        when 'sync'
          data =
            id: evt.id
            name: 'sync'
            options: evt.options
          model = ALL_BACKBONE.getModel evt.id
          options = evt.options
          promise = model.sync evt.method, model, options
          promise.done (value) ->
            data.status = 'done'
            data.value = value
            data.xhr = JSON.parse(JSON.stringify promise)
            SOCKET.emit 'MODEL', data
          promise.fail (error) ->
            data.status = 'fail'
            data.value = error
            data.xhr = JSON.parse(JSON.stringify promise)
            SOCKET.emit 'MODEL', data

        else throw "UNKNOWN event #{evt.name}"

    socket.on 'COLLECTION', (evt) ->
      console.log 'RECEIVED COLLECTION', evt
      switch evt.name
        when 'new'
          collection = ALL_BACKBONE.newCollection evt.url, evt.options
        when 'change'
          collection = ALL_BACKBONE.getCollection evt.url
          models = _.map evt.models, (model) ->
            ALL_BACKBONE.getModel model.id
          collection.set models
          SOCKET.emit 'COLLECTION', evt
        else throw "UNKNOWN event #{evt.name}"




  # ## Start the server
  app.listen(argv.p or 3000, argv.o if argv.o)
  # When server is listening emit a ready event.
  app.emit "ready"
  console.log("Server listening in mode: #{app.settings.env}")

  # Return app when called, so that it can be watched for events and shutdown with .close() externally.
  app
