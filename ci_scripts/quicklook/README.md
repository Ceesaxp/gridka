# Quick Look Apple Silicon regression check

Run on native Apple Silicon macOS with Xcode and XcodeGen:

```sh
xcodegen generate
bash ci_scripts/quicklook/check-arm64.sh
```

The check builds only `GridkaQuickLook` in Release for arm64. It inspects the
processed bundle Info.plist and the actual optimized extension executable in a
native ARM process. No app test suite or DuckDB download is needed.

The test inserts an Objective-C inspection library into a disposable, ad-hoc
signed copy of the executable. Its initializer exits before `NSExtensionMain`.
It checks that the principal class resolves from that executable, subclasses
`QLPreviewProvider`, conforms to `QLPreviewingController`, and declares its own
`providePreviewForFileRequest:completionHandler:` method. An inherited framework
method cannot satisfy the last check. It also checks the extension point,
expanded principal class name, Boolean flags, supported UTIs, and attribute
nesting in the built plist.

Negative controls must reject an optimized executable compiled without the
protocol conformance and a plist with the legacy attribute layout. Expected
`FAIL` lines in those sections demonstrate that the checks detect the regression;
the script succeeds only if the fixed extension passes and both controls fail
for the expected reasons.

This tests class loading, protocol conformance, Objective-C callback exposure,
and bundle metadata. It does not invoke the preview callback, register the
extension, exercise the extension host/sandbox, validate distribution signing,
or show a Finder preview. Production signing, entitlements, parser, and renderer
are unchanged.

For GUI validation, install and launch a normally signed Gridka build on an
Apple Silicon Mac, enable its Quick Look extension, select a small TSV in Finder,
and press Space. Confirm a two-column table with two data rows for:

```sh
printf 'gene\tvalue\nBRCA1\t1\nTP53\t2\n' > sample.tsv
```

Record the commit, macOS version, CPU, and observed table. CI runtime success
does not mark this manual Apple Silicon Finder check as complete.
