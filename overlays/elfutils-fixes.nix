# elfutils 0.195 check failures that come from ElyLD's defaults rather than
# from bad output:
#
#   - test-nlist looks up its own unreferenced globals with nlist(3). ElyLD
#     links with --gc-sections by default, which drops them. Link just that
#     test with --no-gc-sections.
#   - run-backtrace-data.sh derives each module's load base from
#     /proc/PID/maps as `start - offset`, which only holds when every
#     PT_LOAD has p_vaddr == p_offset (GNU ld's -z separate-code layout).
#     ElyLD, like lld, packs segments in the file, so the computed base is a
#     page off and frames in the test binary don't resolve. Skip it.
#
# The other ElyLD-caused failures (strip-nothing, strip-strmerge,
# elflint-self, reverse-sections-self) are fixed in ElyLD itself.
final: prev: {
  elfutils = prev.elfutils.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace tests/Makefile.in \
        --replace-fail 'test_nlist_CFLAGS = -g -O0 $(EXTRA_NLIST_CFLAGS)' \
                       'test_nlist_CFLAGS = -g -O0 $(EXTRA_NLIST_CFLAGS) -Wl,--no-gc-sections'
      sed -i '1a exit 77' tests/run-backtrace-data.sh
    '';
  });
}
