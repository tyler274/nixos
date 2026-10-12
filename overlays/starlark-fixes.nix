# starlark 0.5.0's huge-range limit tests fail on i686 (pkgsi686Linux).
# CPython's len() converts __len__ to a Py_ssize_t, so range(2**40) raises
# OverflowError ("cannot fit 'int' into an index-sized integer") before
# starlark can compare the count to MAX_CONTAINER_ELEMENTS. The check phase
# then sees a wrapped OverflowError instead of "excessive capacity".
# 64-bit CPython only hits this past 2**63-1, which these tests don't use,
# so the same derivation passes there.
#
# The patch reads the Python __len__ after that overflow and still reports
# the Java-reference capacity error. Drop it once nixpkgs ships a starlark
# that does this itself.
final: prev: {
  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (pyFinal: pyPrev: {
      starlark = pyPrev.starlark.overridePythonAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ./patches/starlark/0001-report-ssize-overflow-as-excessive-capacity.patch
        ];
      });
    })
  ];
}
