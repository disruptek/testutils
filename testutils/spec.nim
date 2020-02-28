import std/tables
import std/algorithm
import std/hashes
import std/os
import std/parsecfg
import std/strutils
import std/streams
import std/strtabs

include testament/testament
include testament/specs

import testutils/config

type
  TestOutputs* = StringTableRef
  TestSpec* = ref object
    cmd*: string           # testament likes to provide a compiler call
    check*: TOutputCheck
    shim*: bool            # a shim has no test file per se
    section*: string
    args*: string
    config*: TestConfig
    path*: string
    name*: string
    skip*: bool
    program*: string
    flags*: string
    outputs*: TestOutputs
    timestampPeg*: string
    errorMsg*: string
    maxSize*: int64
    compileError*: string
    errorFile*: string
    errorLine*: int
    errorColumn*: int
    os*: seq[string]
    child*: TestSpec

const
  defaultOptions* = "--verbosity:1 --warnings:on "
  DefaultOses = @["linux", "macosx", "windows"]

proc hash*(spec: TestSpec): Hash =
  var h: Hash = 0
  h = h !& spec.config.hash
  h = h !& spec.flags.hash
  h = h !& spec.os.hash
  result = !$h

proc newTestOutputs*(): StringTableRef =
  result = newStringTable(mode = modeStyleInsensitive)

proc clone*(spec: TestSpec): TestSpec =
  ## create the parent of this test and set the child reference appropriately
  result = new(TestSpec)
  result[] = spec[]
  result.outputs = newTestOutputs()
  result.args = ""
  result.child = spec

func stage*(spec: TestSpec): string =
  ## the name of the output section for the test
  ## Output_test_section_name
  let
    # @["", "test_section_name"]
    names = spec.section.split("Output")
  result = names[^1].replace("_", " ").strip

proc source*(spec: TestSpec): string =
  result = absolutePath(spec.config.path / spec.program.addFileExt(".nim"))

proc binary*(spec: TestSpec; backend: string): string =
  ## some day this will make more sense
  result = absolutePath(spec.source.changeFileExt("").addFileExt(ExeExt))
  if dirExists(result):
    result = result.addFileExt("out")

proc binary*(spec: TestSpec): string {.deprecated.} =
  ## the output binary (execution input) of the test
  result = spec.binary("c")

iterator binaries*(spec: TestSpec): string =
  ## enumerate binary targets for each backend specified by the test
  for backend in spec.config.backends.items:
    yield spec.binary(backend)

proc compilerCommand*(spec: TestSpec; backend: string): string =
  ## create an appropriate compiler command line for the test/backend
  let
    binary = spec.binary(backend)
    nimcache = spec.config.cache(backend)
    compilationFlags = spec.config.compilationFlags

  if spec.shim and spec.cmd != "":
    var
      map = initTable[string, TTarget](rightSize(1 + TTarget.high.ord))
    map["cpp"] = TTarget.targetCpp
    for target in TTarget.low .. TTarget.high:
      map[($target).toLowerAscii] = target
    let
      bend = backend.toLowerAscii
    if bend notin map:
      raise newException(ValueError, "unknown backend: " & bend)
    var
      args = prepareTestArgs(spec.cmd, spec.path, spec.flags, nimcache,
                             target = map[backend.toLowerAscii])
    result = args.join(" ")
  else:
    result = findExe("nim")
    result &= " " & backend
    result &= " --nimcache:" & nimcache
    result &= " " & spec.flags
    result &= " " & spec.config.compilationFlags
  result &= " --out:" & binary
  result &= " " & defaultOptions
  result &= " " & spec.source.quoteShell

proc binaryHash*(spec: TestSpec; backend: string): Hash =
  ## hash the backend, any compilation flags, and defines, etc.
  var h: Hash = 0
  h = h !& backend.hash
  h = h !& spec.os.hash
  h = h !& hash(spec.config.flags * compilerFlags)
  h = h !& hash(spec.flags)
  h = h !& spec.program.hash
  h = h !& hash(spec.compilerCommand(backend))
  result = !$h

proc defaults(spec: var TestSpec) =
  ## assert some default values for a given spec
  spec.os = DefaultOses
  spec.check = TOutputCheck.ocEqual
  spec.outputs = newTestOutputs()
  spec.section = "Output"

proc consumeConfigEvent(spec: var TestSpec; event: CfgEvent) =
  ## parse a specification supplied prior to any sections
  case event.key
  of "program":
    spec.program = event.value
  of "timestamp_peg":
    spec.timestampPeg = event.value
  of "max_size":
    try:
      spec.maxSize = parseInt(event.value)
    except ValueError:
      echo "Parsing warning: value of " & event.key &
           " is not a number (value = " & event.value & ")."
  of "compile_error":
    spec.compileError = event.value
  of "error_file":
    spec.errorFile = event.value
  of "os":
    spec.os = event.value.normalize.split({','} + Whitespace)
  of "affinity":
    spec.config.flags.incl CpuAffinity
  of "threads":
    spec.config.flags.incl UseThreads
  of "nothreads":
    spec.config.flags.excl UseThreads
  of "release", "danger", "debug":
    spec.config.flags.incl parseEnum[FlagKind]("--define:" & event.key)
  else:
    let
      flag = "--define:$#:$#" % [event.key, event.value]
    spec.flags.add flag.quoteShell & " "

proc rewriteTestFile*(spec: TestSpec; outputs: TestOutputs) =
  ## rewrite a test file with updated outputs after having run the tests

  # shims don't have test files, by definition
  if spec.shim:
    return

  var
    test = loadConfig(spec.path)
  # take the opportunity to update an args statement if necessary
  if spec.args != "":
    test.setSectionKey(spec.section, "args", spec.args)
  else:
    test.delSectionKey(spec.section, "args")
  # delete the old test outputs for completeness
  for name, expected in spec.outputs.pairs:
    test.delSectionKey(spec.section, name)
  # add the new test outputs
  for name, expected in outputs.pairs:
    test.setSectionKey(spec.section, name, expected)
  test.writeConfig(spec.path)

proc parseShim(spec: var TestSpec; path: string) =
  try:
    let
      test = path.parseSpec  # parse the file using testament's parser
    var
      output = test.output
    if test.cmd != "":
      spec.cmd = test.cmd
    if test.sortoutput:
      var
        lines = test.output.splitLines(keepEol = true)
      lines.sort
      output = lines.join("")
    spec.outputs["stdout"] = output & "\n"
  except Exception as e:
    echo "not a testament spec: ", spec.path
    # it's probably unittest...

proc parseTestFile*(config: TestConfig; filePath: string): TestSpec =
  ## parse a test input file into a spec
  result = new(TestSpec)
  result.defaults
  result.shim = not filePath.endsWith ".test"
  result.path = absolutePath(filePath)
  result.config = config
  result.name = splitFile(result.path).name
  block:
    # shims don't have a test file, by definition
    if result.shim:
      result.program = result.name
      result.parseShim(result.path)
      break

    var
      f = newFileStream(result.path, fmRead)
    if f == nil:
      # XXX crash?
      echo "Parsing error: cannot open " & result.path
      break

    var
      outputSection = false
      p: CfgParser
    p.open(f, result.path)
    try:
      while true:
        var e = next(p)
        case e.kind
        of cfgEof:
          break
        of cfgError:
          # XXX crash?
          echo "Parsing warning:" & e.msg
        of cfgSectionStart:
          # starts with Output
          if e.section[0..len"Output"-1].cmpIgnoreCase("Output") == 0:
            if outputSection:
              # create our parent; the eternal chain
              result = result.clone
            outputSection = true
            result.section = e.section
        of cfgKeyValuePair:
          if outputSection:
            if e.key.cmpIgnoreStyle("args") == 0:
              result.args = e.value
            else:
              result.outputs[e.key] = e.value
          else:
            result.consumeConfigEvent(e)
        of cfgOption:
          case e.key
          of "skip":
            result.skip = true
          else:
            # this for for, eg. --opt:size
            result.flags &= ("--$#:$#" % [e.key, e.value]).quoteShell & " "
    finally:
      close p

    # we catch this in testrunner and crash there if needed
    if result.program == "":
      echo "Parsing error: no program value"
