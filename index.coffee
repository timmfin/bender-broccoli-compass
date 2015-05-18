fse               = require('fs-extra')
Set               = require('Set')
RSVP              = require('rsvp')
path              = require('path')
exec              = require('child_process').exec
dargs             = require('dargs')
expand            = require('glob-expand')
rimraf            = RSVP.denodeify(require('rimraf'))
helpers           = require('broccoli-kitchen-sink-helpers')
mapSeries         = require('promise-map-series')
objectAssign      = require('object-assign')
GroupedFilter     = require('broccoli-grouped-filter');
symlinkOrCopySync = require('symlink-or-copy').sync

{ pick: pickKeysFrom, zipObject, compact, flatten } = require('lodash')


class BenderCompassCompiler extends GroupedFilter
  description: "BenderCompassCompiler"

  defaultOptions:
    ignoreErrors: false,
    compassCommand: 'compass'

  defaultCommandOptions:
    sassDir: '.'

  constructor: (inputTree, options) ->
    unless this instanceof BenderCompassCompiler
      return new BenderCompassCompiler arguments...

    { @dependencyCache } = options
    @_lastKeys = []

    GroupedFilter.call(this, inputTree, options)

    @options = objectAssign {}, @defaultOptions, options

  canProcessFile: (relativePath) ->
    @hasDesiredExtension(relativePath) is true and @_matchesIncludePattern(relativePath) and @_notPartial(relativePath)

  _matchesIncludePattern: (relativePath) ->
    not @options.includePattern or @options.includePattern.test(relativePath)

  _notPartial: (relativePath) ->
    path.basename(relativePath).charAt(0) isnt '_'

  # SASS can produce more than one output file, but ignoring that for now (need
  # to have a way to say certain files produce more than one output?)
  buildCacheInfoFor: (srcDir, relativePath) ->
    cacheInfo =
      inputFiles: @dependencyCache.dependencyListForFile relativePath, { formatValue: (v) -> v.sourceRelativePath }
      outputFiles: [relativePath.replace(/\.(sass|scss)$/, '.css')]

    cacheInfo


  processFilesInBatch: (srcDir, destDir, filesToProcess) ->
    # Put sass-cache and config file in a separate dir
    if not @extraDir
      @extraDir = destDir + '-compass-extra'
      @compassConfigFile = @extraDir + '/config.rb'
      fse.ensureDirSync(@extraDir)

      fse.writeFileSync(@compassConfigFile, """
        cache_path = "#{@extraDir}/moved-sass-cache"\n
      """)

    # Only run the compass compile if there are any sass files available
    if filesToProcess.length > 0
      @compile(@generateCmdLine(srcDir, destDir, filesToProcess), { cwd: srcDir })
        .catch (err) =>
          msg = err.message ? err

          if options.ignoreErrors is false
            throw err
          else
            console.error(msg)

  cleanup: ->
    # Remove the extra dir
    fse.removeSync(@extraDir)

    # This shouldn't be necessary, but looks like there is a bug with broccoli-filters's
    # pre 0.1.14 support
    this.needsCleanup = true

    super()

  generateCmdLine: (srcDir, destDir, filesToProcess) ->
    cmdArgs = [@options.compassCommand, 'compile']

    # Make a clone and call any functions
    optionsClone = objectAssign {}, @defaultCommandOptions, @options.command,
      cssDir: destDir
      config: @compassConfigFile

    for key, value of optionsClone
      if typeof value is 'function'
        optionsClone[key] = value()

    cmdArgs.concat(dargs(optionsClone)).concat(filesToProcess).join(' ')

  # Add a log/timer to compile
  compile: (cmdLine, options) ->
    start = process.hrtime()

    execPromise = @_actualCompile(cmdLine, options)
    execPromise.then =>
      delta = process.hrtime(start)
      console.log "Compiled #{@filesToProcessInBatch.length} file#{if @filesToProcessInBatch.length is 1 then '' else 's'} via compass in #{Math.round(delta[0] * 1000 + delta[1] / 1000000)}ms"

    execPromise

  _actualCompile: (cmdLine, options) ->
    new RSVP.Promise (resolve, reject) =>
      # console.log "compass command:\n", cmdLine, "(cwd = #{options.cwd})\n\n"

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


module.exports = BenderCompassCompiler
