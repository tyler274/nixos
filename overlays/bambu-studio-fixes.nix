# Bambu Studio 02.08.00.50 aborts under mimalloc-secure during slicing
# because several paths dereference a null shared_ptr<LayeredNozzleGroupResult>
# (Print::process() resets it before wipe-tower / ToolOrdering for sequential
# prints, then *null copies garbage vector state that mi_free rejects).
# Support generation also allocated its layer deque with tbb::scalable_allocator
# while the rest of the process uses mimalloc via ld-nix.so.preload.
#
# These patches keep hardened mimalloc; they stop the second heap and the
# null derefs. See overlays/patches/bambu-studio/.
final: prev: {
  bambu-studio = prev.bambu-studio.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ./patches/bambu-studio/0001-fix-null-nozzle-group-deref.patch
      ./patches/bambu-studio/0002-drop-tbbmalloc-use-process-allocator.patch
      ./patches/bambu-studio/0003-wxmediactrl3-deep-copy-frame.patch
    ];
  });
}
