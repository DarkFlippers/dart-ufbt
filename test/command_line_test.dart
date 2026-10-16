import 'package:dartufbt/dartufbt.dart';
import 'package:test/test.dart';

void main() {
  group('an argument that reads as one thing', () {
    test('is left alone', () {
      expect(quotedArgument('-mthumb'), '-mthumb');
      expect(quotedArgument(r'-IC:\sdk\f7_sdk\furi'), r'-IC:\sdk\f7_sdk\furi');
    });
  });

  group('an argument that would read as two', () {
    // The toolchain and the project both sit under the user profile, which
    // has a space in it often enough to be the normal case rather than the
    // odd one.
    test('a path with a space is quoted whole', () {
      expect(
        quotedArgument(r'-IC:\Users\First Last\.ufbt\current'),
        r'"-IC:\Users\First Last\.ufbt\current"',
      );
    });

    // The one the SDK itself ships: sdk.opts carries this define, and read
    // back without quoting it names a different macro than the one that ran.
    test('a define whose value is quoted keeps its quotes', () {
      expect(
        quotedArgument('-DMBEDTLS_CONFIG_FILE="mbedtls_cfg.h"'),
        r'"-DMBEDTLS_CONFIG_FILE=\"mbedtls_cfg.h\""',
      );
    });

    test('a define holding a call is left alone, having no space', () {
      expect(
        quotedArgument('-DM_MEMORY_FULL(x)=abort()'),
        isNot(startsWith('"')),
      );
    });
  });

  group('the whole line', () {
    test('names the executable first and quotes it too', () {
      expect(
        quotedCommandLine(r'C:\tools\arm none\gcc.exe', const ['-c', 'a.c']),
        r'"C:\tools\arm none\gcc.exe" -c a.c',
      );
    });

    test('is the executable alone when nothing was passed', () {
      expect(quotedCommandLine('nm', const []), 'nm');
    });
  });
}
