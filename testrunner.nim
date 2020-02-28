import std/hashes
import std/random
import std/tables
import std/sequtils
import std/strtabs
import std/os
import std/osproc
import std/strutils
import std/terminal
import std/times
import std/pegs
import std/algorithm

# for shimming testament tests
include testament/specs

import testutils/spec
import testutils/config
import testutils/helpers

##[

The runner will look recursively for all *.test files at given path. A
test file should have at minimum a program name. This is the name of the
nim source minus the .nim extension)

]##


# Code is here and there influenced by nim testament tester and unittest
# module.

const
  # defaultOptions = "--verbosity:1 --warnings:off --hint[Processing]:off " &
  #                  "--hint[Conf]:off --hint[XDeclaredButNotUsed]:off " &
  #                  "--hint[Link]:off --hint[Pattern]:off"
  backendOrder = @["c", "cpp", "js"]

type
  TestStatus* = enum
    OK
    FAILED
    SKIPPED
    INVALID

  #[
   If needed, pass more info to the logresult via a TestResult object
   TestResult = object
     status: TestStatus
     compileTime: float
     fileSize: uint
  ]#

  ThreadPayload = object
    core: int
    spec: TestSpec

  TestThread = Thread[ThreadPayload]
  TestError* = enum
    SourceFileNotFound
    ExeFileNotFound
    OutputFileNotFound
    CompileError
    RuntimeError
    OutputsDiffer
    FileSizeTooLarge
    CompileErrorDiffers

  BackendTests = TableRef[string, seq[TestSpec]]

proc logFailure(test: TestSpec; error: TestError;
                data: varargs[string] = [""]) =
  case error
  of SourceFileNotFound:
    styledEcho(fgYellow, styleBright, "source file not found: ",
               resetStyle, test.source)
  of ExeFileNotFound:
    styledEcho(fgYellow, styleBright, "file not found: ",
               resetStyle, test.binary)
  of OutputFileNotFound:
    styledEcho(fgYellow, styleBright, "file not found: ",
               resetStyle, data[0])
  of CompileError:
    styledEcho(fgYellow, styleBright, "compile error:\p",
               resetStyle, data[0])
  of RuntimeError:
    styledEcho(fgYellow, styleBright, "runtime error:\p",
               resetStyle, data[0])
  of OutputsDiffer:
    styledEcho(fgYellow, styleBright, "outputs are different:\p",
               resetStyle,"Expected output to $#:\p$#" % [data[0], data[1]],
                          "Resulted output to $#:\p$#" % [data[0], data[2]])
  of FileSizeTooLarge:
    styledEcho(fgYellow, styleBright, "file size is too large: ",
               resetStyle, data[0] & " > " & $test.maxSize)
  of CompileErrorDiffers:
    styledEcho(fgYellow, styleBright, "compile error is different:\p",
               resetStyle, data[0])

  styledEcho(fgCyan, styleBright, "compiler: ", resetStyle,
             "$# $# $# $#" % [defaultOptions,
                              test.flags,
                              test.config.compilationFlags,
                              test.source])

template withinDir(dir: string; body: untyped): untyped =
  ## run the body with a specified directory, returning to current dir
  let
    cwd = getCurrentDir()
  setCurrentDir(dir)
  try:
    body
  finally:
    setCurrentDir(cwd)

proc logResult(testName: string, status: TestStatus, time: float) =
  var color = block:
    case status
    of OK: fgGreen
    of FAILED: fgRed
    of SKIPPED: fgYellow
    of INVALID: fgRed
  styledEcho(styleBright, color, "[", $status, "] ",
             resetStyle, testName,
             fgYellow, " ", time.formatFloat(ffDecimal, 3), " s")

template time(duration, body): untyped =
  let t0 = epochTime()
  block:
    body
  duration =  epochTime() - t0

proc composeOutputs(test: TestSpec, stdout: string): TestOutputs =
  ## collect the outputs for the given test
  result = newTestOutputs()
  for name, expected in test.outputs.pairs:
    if name == "stdout":
      result[name] = stdout
    else:
      if not existsFile(name):
        continue
      result[name] = readFile(name)
      removeFile(name)

proc cmpOutputs(test: TestSpec, outputs: TestOutputs): TestStatus =
  ## compare the test program's outputs to those expected by the test
  result = OK
  for name, expected in test.outputs.pairs:
    if name notin outputs:
      logFailure(test, OutputFileNotFound, name)
      result = FAILED
      continue

    let
      testOutput = outputs[name]

    # Would be nice to do a real diff here instead of simple compare
    if test.timestampPeg.len > 0:
      if not cmpIgnorePegs(testOutput, expected, test.check,
                           peg(test.timestampPeg), pegXid):
        logFailure(test, OutputsDiffer, name, expected, testOutput)
        result = FAILED
    else:
      if not cmpIgnoreDefaultTimestamps(testOutput, expected, test.check):
        logFailure(test, OutputsDiffer, name, expected, testOutput)
        result = FAILED

proc compile(test: TestSpec; backend: string): TestStatus =
  ## compile the test program for the requested backends
  block:
    if not existsFile(test.source):
      logFailure(test, SourceFileNotFound)
      result = FAILED
      break

    let
      binary = test.binary(backend)
    var
      cmd = test.compilerCommand(backend)
      c = parseCmdLine(cmd)
      p = startProcess(command=c[0], args=c[1.. ^1],
                       options={poStdErrToStdOut, poUsePath})

    try:
      let
        compileInfo = parseCompileStream(p, p.outputStream)

      if compileInfo.exitCode != 0:
        if test.compileError.len == 0:
          logFailure(test, CompileError, compileInfo.fullMsg)
          result = FAILED
          break
        else:
          if test.compileError == compileInfo.msg and
             (test.errorFile.len == 0 or test.errorFile == compileInfo.errorFile) and
             (test.errorLine == 0 or test.errorLine == compileInfo.errorLine) and
             (test.errorColumn == 0 or test.errorColumn == compileInfo.errorColumn):
            result = OK
          else:
            logFailure(test, CompileErrorDiffers, compileInfo.fullMsg)
            result = FAILED
            break

      # Lets also check file size here as it kinda belongs to the
      # compilation result
      if test.maxSize != 0:
        var size = getFileSize(binary)
        if size > test.maxSize:
          logFailure(test, FileSizeTooLarge, $size)
          result = FAILED
          break

      result = OK
    finally:
      close(p)

proc threadedExecute(payload: ThreadPayload) {.thread.}

proc spawnTest(child: var Thread[ThreadPayload]; test: TestSpec;
               core: int): bool =
  ## invoke a single test on the given thread/core; true if we
  ## pinned the test to the given core
  assert core >= 0
  child.createThread(threadedExecute,
                     ThreadPayload(core: core, spec: test))
  # set cpu affinity if requested (and cores remain)
  if CpuAffinity in test.config.flags:
    if core < countProcessors():
      child.pinToCpu core
      result = true

proc executeOne(test: TestSpec): TestStatus =
  ## invoke a single test and return a status
  var
    # FIXME: pass a backend
    cmd = test.binary
  # output the test stage if necessary
  if test.stage.len > 0:
    echo 20.spaces & test.stage

  if not fileExists(cmd):
    result = FAILED
    logFailure(test, ExeFileNotFound)
  else:
    withinDir parentDir(test.path):
      cmd = cmd.quoteShell & " " & test.args
      let
        (output, exitCode) = execCmdEx(cmd)
      if exitCode != 0:
        # parseExecuteOutput() # Need to parse the run time failures?
        logFailure(test, RuntimeError, output)
        result = FAILED
      else:
        let
          outputs = test.composeOutputs(output)
        result = test.cmpOutputs(outputs)
        # perform an update of the testfile if requested and required
        if UpdateOutputs in test.config.flags and result == FAILED:
          test.rewriteTestFile(outputs)
          # we'll call this a `skip` because it's not strictly a failure
          # and we want any dependent testing to proceed as usual.
          result = SKIPPED

proc executeAll(test: TestSpec): TestStatus =
  ## run a test and any dependent children, yielding a single status
  when compileOption("threads"):
    try:
      var
        thread: TestThread
      # we spawn and join the test here so that it can receive
      # cpu affinity via the standard thread.pinToCpu method
      discard thread.spawnTest(test, 0)
      thread.joinThreads
    except:
      # any thread(?) exception is a failure
      result = FAILED
  else:
    # unthreaded serial test execution
    result = SKIPPED
    while test != nil and result in {OK, SKIPPED}:
      result = test.executeOne
      test = test.child

proc threadedExecute(payload: ThreadPayload) {.thread.} =
  ## a thread in which we'll perform a test execution given the payload
  var
    result = FAILED
  if payload.spec.child == nil:
    {.gcsafe.}:
      result = payload.spec.executeOne
  else:
    try:
      var
        child: TestThread
      discard child.spawnTest(payload.spec.child, payload.core + 1)
      {.gcsafe.}:
        result = payload.spec.executeOne
      child.joinThreads
    except:
      result = FAILED
  if result == FAILED:
    raise newException(CatchableError, payload.spec.stage & " failed")

proc optimizeOrder(tests: seq[TestSpec];
                   order: set[SortBy]): seq[TestSpec] =
  ## order the tests by how recently each was modified
  template whenWritten(path: string): Time =
    path.getFileInfo(followSymlink = true).lastWriteTime

  result = tests
  for s in SortBy.low .. SortBy.high:
    if s in order:
      case s
      of Test:
        result = result.sortedByIt it.path.whenWritten
      of Source:
        result = result.sortedByIt it.source.whenWritten
      of Reverse:
        result.reverse
      of Random:
        randomize()
        result.shuffle

proc scanTestPath(path: string; ext: string): seq[string] =
  ## add any tests found at the given path
  if fileExists(path) and path.endsWith(ext):
    result.add path
  else:
    for file in walkDirRec path:
      if file.endsWith ext:
        result.add file

proc findTests(config: TestConfig): seq[TestSpec] =
  let
    testFiles = scanTestPath(config.path, ".test")
  result = testFiles.mapIt config.parseTestFile(it)
  if Shim in config.flags:
    let
      nimFiles = scanTestPath(config.path, ".nim")
    for source in nimFiles.items:
      let
        source = absolutePath(source)
      if not result.anyIt it.source == source:
        result.add config.parseTestFile(source)

proc test(test: TestSpec; backend: string): TestStatus =
  var
    duration: float

  try:
    time duration:
      # perform all tests in the test file
      result = test.executeAll
  finally:
    logResult(test.name, result, duration)

proc buildBackendTests(config: TestConfig;
                       tests: seq[TestSpec]): BackendTests =
  ## build the table mapping backend to test inputs
  result = newTable[string, seq[TestSpec]](4)
  for spec in tests.items:
    for backend in config.backends.items:
      assert backend != ""
      if backend in result:
        if spec notin result[backend]:
          result[backend].add spec
      else:
        result[backend] = @[spec]

proc removeCaches(config: TestConfig; backend: string) =
  ## cleanup nimcache directories between backend runs
  removeDir config.cache(backend)

# we want to run tests on "native", first.
proc performTesting(config: TestConfig;
                    backend: string; tests: seq[TestSpec]): TestStatus =
  var
    successful, skipped = 0
    dedupe: CountTable[Hash]

  assert backend != ""

  # perform each test in an optimized order
  for spec in tests.optimizeOrder(config.orderBy).items:
    if spec.program.len == 0:
      # a program name is bare minimum of a test file
      result = INVALID
      break

    if spec.skip or hostOS notin spec.os or config.shouldSkip(spec.name):
      result = SKIPPED
      break

    let
      build = spec.binaryHash(backend)
    if build notin dedupe:
      dedupe.inc build
      # compile the test program for all backends
      var
        duration: float
      try:
        time duration:
          result = compile(spec, backend)
          if result != OK or spec.compileError.len != 0:
            break
      finally:
        logResult("compiled " & spec.program & " for " & spec.name,
                  result, duration)

    if result == OK:
      case spec.test(backend)
      of OK:
        successful.inc
      of SKIPPED:
        skipped.inc
      else: discard

  styledEcho(styleBright, "Finished run for $#: $#/$# tests successful" %
                          [backend, $successful,
                           $(tests.len - skipped)])

  for spec in tests.items:
    try:
      # this may fail in 64-bit AppVeyor images with "The process cannot
      # access the file because it is being used by another process.
      # [OSError]"
      let
        fn = spec.binary(backend)
      if fileExists(fn):
        removeFile(fn)
    except CatchableError as e:
      echo e.msg

  if 0 == tests.len - successful - skipped:
    config.removeCaches(backend)

proc main(): int =
  let
    config = processArguments()
    tests = findTests(config)

  if tests.len == 0:
    styledEcho(styleBright, "No test files found")
    result = 1
  else:
    var
      backends = config.buildBackendTests(tests)

    # c > cpp > js
    for backend in backendOrder:
      assert backend != ""
      # if we actually need to do anything on the given backend
      if backend notin backends:
        continue
      let
        tests = backends[backend]
      try:
        if OK != config.performTesting(backend, tests):
          break
      finally:
        backends.del(backend)

    for backend, tests in backends.pairs:
      assert backend != ""
      if OK != config.performTesting(backend, tests):
        break

when isMainModule:
  quit main()
