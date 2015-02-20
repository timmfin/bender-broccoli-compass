RSVP            = require('rsvp')
path            = require('path')
expand          = require('glob-expand')
rimraf          = RSVP.denodeify(require('rimraf'))
dargs           = require('dargs')
helpers         = require('broccoli-kitchen-sink-helpers')
mapSeries       = require('promise-map-series')
objectAssign    = require('object-assign')
symlinkOrCopy   = require('symlink-or-copy')
CompassCompiler = require('broccoli-compass')

class BenderCompassCompiler extends CompassCompiler
  enforceSingleInputTree: true

  constructor: (@options) ->
    unless this instanceof BenderCompassCompiler
      return new BenderCompassCompiler arguments...

    { @dependencyCache } = @options

    super arguments...

  relevantFilesFromSource: (srcDir, options) ->
    expand
      cwd: srcDir
      dot: true
      filter: 'isFile'
    , [
      # Copy call the source and compiled output
      '**/*.{scss,sass,css}'

      # Make sure that we copy across partials too (for later dep tree cache
      # invalidation checks, plus others that need it)
      '**/_*.{scss,sass}'

      # Exclude sass-cache (should this be pulled from options.exclude instead?)
      '!.sass-cache/**'
    ]


  lookupAllSassFiles: (srcDir) ->
    @perBuildCache.allSassFiles ?= expand
      cwd: srcDir
      dot: true
      filter: 'isFile'
    , [
      # Ignore partials when looking if a compile is necessary
      '**/[^_]*.{scss,sass}'

      '!.sass-cache/**'
    ]

  numSassFilesIn: (srcDir) ->
    @perBuildCache.numSassFiles ?= @lookupAllSassFiles(srcDir).length

  hasAnySassFiles: (srcDir) ->
    @numSassFilesIn(srcDir) > 0

  updateCache: (srcDir, destDir) ->
    # Needs to be run every rebuild now
    @generateCmdLine()

    # Only run the compass compile if there are any sass files available
    if @hasAnySassFiles srcDir
      super srcDir, destDir
    else
      # Still need to call copyRelevant to copy across partials (even if there
      # are no real sass files to compile)
      @copyRelevant(srcDir, destDir, @options).then ->
        destDir

  resolvedDependenciesForAllFiles: (relativePaths, options) ->
    @dependencyCache.listOfAllResolvedDependencyPathsMulti(relativePaths, options) ? []

  getHashForInput: (inputTreeDir) ->
    keys = @keysForTree(inputTreeDir)
    hashFromInputTree = helpers.hashStrings(keys)

    loadPaths = [inputTreeDir].concat @passedLoadPaths()
    allSassFiles = @lookupAllSassFiles(inputTreeDir)
    resolvedDepsPlusSelf = @resolvedDependenciesForAllFiles(allSassFiles, { loadPaths }) ? allSassFiles

    hashes = for resolvedPath in resolvedDepsPlusSelf
      helpers.hashTree resolvedPath

    "#{hashFromInputTree},#{helpers.hashStrings(hashes)}"

  passedLoadPaths: ->
    # options.loadPaths might be a function
    @options.loadPaths?() ? @options.loadPaths ? []

  # Have to copy this if we are customizing generateCmdLine
  ignoredOptions: [
    'compassCommand'
    'ignoreErrors'
    'exclude'
    'files'
    'filterFromCache'

    'dependencyCache'
    'loadPaths'
  ]

  # Override generateCmdLine so that we can use a function to define command arguments
  generateCmdLine: ->
    cmd = [@options.compassCommand, 'compile']
    cmdArgs = cmd.concat(@options.files)

    # Make a clone and call any functions
    optionsClone = objectAssign {}, @options

    for key, value of optionsClone
      if typeof value is 'function'
        optionsClone[key] = value()

    @cmdLine = cmdArgs.concat(dargs(optionsClone, { excludes: @ignoredOptions })).join(' ')

  # Add a log/timer to compile
  compile: ->
    start = process.hrtime()

    execPromise = super
    execPromise.then =>
      delta = process.hrtime(start)
      console.log "Compiled #{@perBuildCache.numSassFiles} file#{if @perBuildCache.numSassFiles is 1 then '' else 's'} via compass in #{Math.round(delta[0] * 1000 + delta[1] / 1000000)}ms"

    execPromise

  # Override so that the source files are _not_ deleted (but still need to delete
  # the `.sass-cache/` folder)
  cleanupSource: (srcDir, options) ->
    return new RSVP.Promise (resolve) ->
      rimraf path.join(srcDir, '.sass-cache'), resolve


  # Override the broccoli-caching-writers's implementation of read so we can customize
  # the cache hash (sigh... maybe we really should just include all dependencies into
  # one giant tree...)
  read: (readTree) ->

    # NEW ADDITION
    # Broccoli gaurentees that this method will only be called once per build
    @preBuildCleanup()

    mapSeries(this.inputTrees, readTree).then (inputPaths) =>
      inputTreeHashes = []
      invalidateCache = false
      keys = dir = updateCacheResult = undefined

      for dir, i in inputPaths
        # OLD
        # keys = @keysForTree(dir)
        # inputTreeHashes[i] = helpers.hashStrings(keys)

        # CHANGE
        inputTreeHashes[i] = @getHashForInput(dir)


        invalidateCache = true if @_inputTreeCacheHash[i] isnt inputTreeHashes[i]

      if invalidateCache
        updateCacheSrcArg = if @enforceSingleInputTree then inputPaths[0] else inputPaths
        updateCacheResult = @updateCache(updateCacheSrcArg, @getCleanCacheDir())

        @_inputTreeCacheHash = inputTreeHashes

      updateCacheResult
    .then =>
      rimraf @_destDir
    .then =>
      symlinkOrCopy.sync(@getCacheDir(), @_destDir)
    .then =>
      @_destDir

  preBuildCleanup: ->
    @perBuildCache = {}



module.exports = BenderCompassCompiler
