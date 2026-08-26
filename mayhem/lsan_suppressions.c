/* Baked-in LeakSanitizer suppressions for the fuzz harnesses.
 *
 * libgcrypt keeps a couple of tiny process-lifetime allocations (e.g. a
 * strdup'd algorithm name via _gcry_strdup_core) that it never frees.
 * Those are dependency-internal, not gnupg code and not harness memory.
 * Leak detection stays ON for everything else (gnupg + harness), so a
 * genuine gnupg leak still fails the run.
 */
const char *__lsan_default_suppressions(void) {
  return "leak:libgcrypt\nleak:_gcry_\n";
}
