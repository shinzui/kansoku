-- OKF profile descriptor written by `okf profile init`.
-- 
-- Profile: documentation.researchDocuments
-- Source:  https://raw.githubusercontent.com/shinzui/okf-profiles/v0.25.0/package.dhall
-- 
-- Existing hashes are preserved and unhashed remote value imports are frozen.
-- Local and environment inputs remain live; this is not a portable snapshot.
-- To update remote imports, remove their hashes and run `dhall freeze profile.dhall`.
-- Never hand-write a sha256 value.
let registry =
      https://raw.githubusercontent.com/shinzui/okf-profiles/v0.25.0/package.dhall
        sha256:ec74cc6f7b8ee1a5af81ee7fc8804f35cf2c9ba4010671d9e881da72eb6719d3

in  registry.documentation.researchDocuments
