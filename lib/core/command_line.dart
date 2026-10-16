/// Renders a process invocation as one line, each argument quoted so a reader
/// can tell where it ends.
///
/// `Process.run` takes argv, where an argument holding a space is still one
/// argument - written out plainly it reads as two, and `-DNAME="value"` reads
/// as something a shell would strip the quotes from. Both are routine here:
/// the toolchain sits under the user profile, which on Windows has a space in
/// it often enough, and the SDK's own options carry quoted defines.
///
/// The quoting is the convention Windows argv parsing and POSIX shells both
/// read. It is evidence for a bug report that names its arguments
/// unambiguously, not a line promised to paste into every shell - `cmd.exe`
/// does not read `\"` this way.
String quotedCommandLine(String executable, List<String> arguments) =>
    [executable, ...arguments].map(quotedArgument).join(' ');

/// One argv element, quoted when it would otherwise read as more than one.
///
/// `hasMatch` rather than `argument.contains(_needsQuoting)`: `String.contains`
/// takes a `Pattern` through `indexOf`, which runs the expression anchored at
/// every character position - 45x slower here, on arguments that are mostly
/// long include paths needing no quotes at all.
String quotedArgument(String argument) => _needsQuoting.hasMatch(argument)
    ? '"${argument.replaceAll('"', r'\"')}"'
    : argument;

final RegExp _needsQuoting = RegExp(r'[\s"]');
