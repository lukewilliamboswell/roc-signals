# Generated macOS linker interface provenance

These `.tbd` files are generated from scratch by Roc Signals. They are minimal
YAML descriptions containing the interface symbols selected for the compiled
host, their library paths, and the target architecture. Their purpose is
interoperability between the compiled GUI host and macOS.

The accompanying `interfaces.json` records the source URLs used for each
interface. Sources include Apple's publicly available developer documentation
and identified open-source declarations for runtime ABI and GPUI framework
imports. The records were assembled using automated documentation retrieval and
source review. Generation uses the committed catalog entirely offline.
The independent interface producer reads that catalog and this provenance
statement. It does not read, copy, or modify Apple SDK headers, linker stubs,
framework binaries, or compiled host archives. The manifest records the catalog,
generator, provenance, and generated-file hashes.

Released host archives are separate validation inputs: after generation, native
application links and specs check the candidate interfaces against a selected
host release and its matching source revision. Host archive identity is not part
of the generated interface archive's identity.

The generated interface package redistributes no proprietary Apple software,
Apple SDK files, or SDK agreements.

These files contain linking metadata. The final application link occurs on the
user's machine during compilation with Roc. macOS provides the framework and
system-library implementations at runtime.
