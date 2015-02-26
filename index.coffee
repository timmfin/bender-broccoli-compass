fse             = require('fs-extra')
Set             = require('Set')
RSVP            = require('rsvp')
path            = require('path')
exec            = require('child_process').exec
expand          = require('glob-expand')
rimraf          = RSVP.denodeify(require('rimraf'))
dargs           = require('dargs')
helpers         = require('broccoli-kitchen-sink-helpers')
mapSeries       = require('promise-map-series')
objectAssign    = require('object-assign')
symlinkOrCopy   = require('symlink-or-copy')
CachingWriter   = require('broccoli-caching-writer');

{ pick: pickKeysFrom, zipObject, compact } = require('lodash')


class BenderCompassCompiler extends CachingWriter
  enforceSingleInputTree: true

  defaultOptions:
    ignoreErrors: false,
    compassCommand: 'compass'

  # Since CachingWriter copies options to the intstance, only send what it needs
  optionKeysForCachingWriter: [
    'filterFromCache'
  ]

  constructor: (inputTree, options) ->
    unless this instanceof BenderCompassCompiler
      return new BenderCompassCompiler arguments...

    { @dependencyCache } = options
    @_lastKeys = []

    super inputTree, pickKeysFrom(options, @optionKeysForCachingWriter)

    # Fixup CachingWriter (CoreObject?) goofing with options (and set defaults)
    @options = objectAssign {}, @defaultOptions, options

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

      # Exclude sass-cache
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

    # Only run the compass compile if there are any sass files available
    if @hasAnySassFiles srcDir
      @_actuallyUpdateCache srcDir, destDir
    else
      # Still need to call copyRelevant to copy across partials (even if there
      # are no real sass files to compile)
      @copyRelevant(srcDir, destDir, @options).then ->
        destDir

  _actuallyUpdateCache: (srcDir, destDir) ->
    console.log "srcDir", srcDir
    @compile(@generateCmdLine(), { cwd: srcDir })
      .then =>
        @copyRelevant(srcDir, destDir, options)
      .then =>
        @cleanupSource(srcDir, options)
      .then =>
        destDir
      , (err) =>
        msg = err.message ? err

        if options.ignoreErrors is false
          throw err
        else
          console.error(msg)

  copyRelevant: (srcDir, destDir, options) ->
    results = @relevantFilesFromSource(srcDir, options)

    copyPromises = for result in results
      @copyDir(path.join(srcDir, result), path.join(destDir, result))

    RSVP.all(copyPromises)

  copyDir: (srcDir, destDir) ->
    return new RSVP.Promise (resolve, reject) ->
      fse.copy srcDir, destDir, (err) ->
        return reject(err) if err
        resolve()

  resolvedDependenciesForAllFiles: (relativePaths, options) ->
    @dependencyCache.listOfAllResolvedDependencyPathsMulti(relativePaths, options) ? []

  getHashForInput: (inputTreeDir) ->
    originalKey = @keyForTree(inputTreeDir)

    loadPaths = [inputTreeDir].concat @passedLoadPaths()
    allSassFiles = new Set @lookupAllSassFiles(inputTreeDir)
    resolvedDepsMinusSelf = @resolvedDependenciesForAllFiles(allSassFiles.toArray(), { loadPaths, ignoreSelf: true, relativePlusDirObject: true }) ? []

    childKeys = for { resolvedDir, resolvedRelativePath } in resolvedDepsMinusSelf
      resolvedPath = resolvedDir + '/' + resolvedRelativePath
      childKey = @keyForTree resolvedPath, resolvedRelativePath unless allSassFiles.contains(resolvedRelativePath)

    originalKey.children = originalKey.children.concat(compact(childKeys))
    originalKey

  passedLoadPaths: ->
    # options.loadPaths might be a function
    @options.loadPaths?() ? @options.loadPaths ? []

  generateCmdLine: ->
    cmdArgs = [@options.compassCommand, 'compile']

    # Make a clone and call any functions
    optionsClone = objectAssign {}, @options.command

    for key, value of optionsClone
      if typeof value is 'function'
        optionsClone[key] = value()

    cmdArgs.concat(dargs(optionsClone)).join(' ')

  # Add a log/timer to compile
  compile: ->
    start = process.hrtime()

    execPromise = super
    execPromise.then =>
      delta = process.hrtime(start)
      console.log "Compiled #{@perBuildCache.numSassFiles} file#{if @perBuildCache.numSassFiles is 1 then '' else 's'} via compass in #{Math.round(delta[0] * 1000 + delta[1] / 1000000)}ms"

    execPromise

  compile: (cmdLine, options) ->
    new RSVP.Promise (resolve, reject) =>
      exec cmdLine, options, (err, stdout, stderr) =>
        if not err
          resolve()
        else
          # Provide a robust error message in case of failure.
          # compass sends errors to sdtout, so it's important to include that
          err.message = """
            [broccoli-compass] failed while executing compass command line
            [broccoli-compass] Working directory: #{options.cwd}
            [broccoli-compass] Executed: #{cmdLine}
            [broccoli-compass] stdout:\n#{stdout}
            [broccoli-compass] stderr:\n#{stderr}
          """

          reject(err)

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
      invalidateCache = false
      keys = dir = updateCacheResult = undefined
      lastKeys = []


      for dir, i in inputPaths
        key = @getHashForInput(dir)
        lastKey = @_lastKeys[i]
        lastKeys.push(key)

        invalidateCache = true unless key.equal(lastKey)

      if invalidateCache
        updateCacheSrcArg = if @enforceSingleInputTree then inputPaths[0] else inputPaths
        updateCacheResult = @updateCache(updateCacheSrcArg, @getCleanCacheDir())

        @_lastKeys = lastKeys

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
