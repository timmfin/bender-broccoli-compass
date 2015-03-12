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

{ pick: pickKeysFrom, zipObject, compact, flatten } = require('lodash')


class BenderCompassCompiler extends CachingWriter
  defaultOptions:
    ignoreErrors: false,
    compassCommand: 'compass'

  defaultCommandOptions:
    sassDir: '.'
    cssDir: '.'

  # Since CachingWriter copies options to the instance only send what it needs
  optionKeysForCachingWriter: [
    'filterFromCache'
  ]

  constructor: (inputTree, options) ->
    unless this instanceof BenderCompassCompiler
      return new BenderCompassCompiler arguments...

    { @dependencyCache } = options
    @_lastKeys = []

    # CoreObject (used inside CachingWriter) doesn't like being called via super
    CachingWriter.call this, [inputTree], pickKeysFrom(options, @optionKeysForCachingWriter)

    # Fixup CachingWriter (CoreObject?) goofing with options (and set defaults)
    @options = objectAssign {}, @defaultOptions, options

    # For now, can only be something like `Bla/` or `Bla/**` (eg. it can't filter for
    # the actual file or extension, only the beginning of the path)
    @options.restrictedDirPatterns ?= []
    throw new Error "restrictedDirPatterns needs to be an array" unless @options.restrictedDirPatterns?.length

  relevantFilesFromSource: (srcDir, options) ->
    patterns = @_buildIncludePatterns @options.restrictedDirPatterns, [
      # Copy call the source and compiled output (including '_' partials too)
      '**/*.{scss,sass,css}'
    ]

    expand
      cwd: srcDir
      dot: true
      filter: 'isFile'

      # Much faster that `!` negation
      ignore: [
        '.sass-cache/**'
      ]
    , patterns


  lookupAllSassFiles: (srcDir) ->
    @perBuildCache.allSassFiles ?= expand
      cwd: srcDir
      dot: true
      filter: 'isFile'

      # Much faster that `!` negation
      ignore: [
        '.sass-cache/**'
      ]
    , @_buildIncludePatterns @options.restrictedDirPatterns, [
      # Ignore partials when looking if a compile is necessary
      '**/[^_]*.{scss,sass}'
    ]


  # For now assumes it is ok to concatenate the dir and include patterns (because
  # you can only restrict directories)
  _buildIncludePatterns: (restrictedDirPatterns, includePatterns) ->

    # Empty "pattern" if there are not restrictions
    restrictedDirPatterns = [''] if restrictedDirPatterns.length is 0

    patterns = for restrictedDirPattern in restrictedDirPatterns
      for includePattern in includePatterns
        "#{restrictedDirPattern}#{includePattern}".replace('****', '**')  # to merge '/**' and '**/'

    flatten(patterns)


  numSassFilesIn: (srcDir) ->
    @perBuildCache.numSassFiles ?= @lookupAllSassFiles(srcDir).length

  hasAnySassFiles: (srcDir) ->
    @numSassFilesIn(srcDir) > 0

  updateCache: (srcDirs, destDir) ->
    srcDir = srcDirs[0]

    # Only run the compass compile if there are any sass files available
    if @hasAnySassFiles srcDir
      @_actuallyUpdateCache srcDir, destDir
    else
      # Still need to call copyRelevant to copy across partials (even if there
      # are no real sass files to compile)
      @copyRelevant(srcDir, destDir, @options).then ->
        destDir

  _actuallyUpdateCache: (srcDir, destDir) ->
    @compile(@generateCmdLine(srcDir), { cwd: srcDir })
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

  passedLoadPaths: ->
    # options.loadPaths might be a function
    @options.loadPaths?() ? @options.loadPaths ? []

  generateCmdLine: (srcDir) ->
    cmdArgs = [@options.compassCommand, 'compile']

    # Make a clone and call any functions
    optionsClone = objectAssign {}, @defaultCommandOptions, @options.command

    for key, value of optionsClone
      if typeof value is 'function'
        optionsClone[key] = value()

    cmdArgs.concat(dargs(optionsClone)).concat(@lookupAllSassFiles(srcDir)).join(' ')

  # Add a log/timer to compile
  compile: (cmdLine, options) ->
    start = process.hrtime()

    execPromise = @_actualCompile(cmdLine, options)
    execPromise.then =>
      delta = process.hrtime(start)
      console.log "Compiled #{@perBuildCache.numSassFiles} file#{if @perBuildCache.numSassFiles is 1 then '' else 's'} via compass in #{Math.round(delta[0] * 1000 + delta[1] / 1000000)}ms"

    execPromise

  _actualCompile: (cmdLine, options) ->
    new RSVP.Promise (resolve, reject) =>
      console.log "compass command:\n", cmdLine, "\n\n"
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


  # Override the broccoli-caching-writers's implementation of read so we can add
  # some per build cleanup (can go else where?)
  read: (readTree) ->

    # NEW ADDITION
    # Broccoli gaurentees that this method will only be called once per build
    @preBuildCleanup()

    CachingWriter.prototype.read.call(this, readTree)

  preBuildCleanup: ->
    @perBuildCache = {}



module.exports = BenderCompassCompiler
