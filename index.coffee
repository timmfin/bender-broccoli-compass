rsvp            = require('rsvp')
path            = require('path')
expand          = require('glob-expand')
rimraf          = require('rimraf')
dargs           = require('dargs')
objectAssign    = require('object-assign')
CompassCompiler = require('broccoli-compass')



class BenderCompassCompiler extends CompassCompiler
  constructor: ->
    unless this instanceof BenderCompassCompiler
      return new BenderCompassCompiler arguments...

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

  hasAnySassFiles: (srcDir) ->
    # TODO, optimize to stop after finding the first file? (need to use something
    # other than globbing)
    sassFiles = expand
      cwd: srcDir
      dot: true
      filter: 'isFile'
    , [
      # Ignore partials when looking if a compile is necessary
      '**/[^_]*.{scss,sass}'

      '!.sass-cache/**'
    ]

    sassFiles.length > 0


  # updateCache: (srcDir, destDir) ->
  #   start = process.hrtime()

  #   super(srcDir, destDir).finally () ->
  #     diff = process.hrtime(start)
  #     console.log("Took: ", diff[0] + (diff[1] / 1000000000))

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

  # Have to copy this if we are customizing generateCmdLine
  ignoredOptions: [
    'compassCommand'
    'ignoreErrors'
    'exclude'
    'files'
    'filterFromCache'
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

  # Override so that the source files are _not_ deleted (but still need to delete
  # the `.sass-cache/` folder)
  cleanupSource: (srcDir, options) ->
    return new rsvp.Promise (resolve) ->
      rimraf path.join(srcDir, '.sass-cache'), resolve



module.exports = BenderCompassCompiler
