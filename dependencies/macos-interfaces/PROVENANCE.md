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
The generator reads that catalog and hashes the compiled host archives; it does
not read, copy, or modify Apple SDK headers, linker stubs, or framework binaries.
The manifest records the exact inputs and generated-file hashes.

The generated interface package redistributes no proprietary Apple software,
Apple SDK files, or SDK agreements.

These files contain linking metadata. The final application link occurs on the
user's machine during compilation with Roc. macOS provides the framework and
system-library implementations at runtime.
