# Third-party notices

The MIT license in this repository applies to StorageDaddy's original source
code and documentation. Third-party code and brand assets retain their own
terms; this repository does not grant rights to third-party trademarks.

- **Sparkle** provides app updates under its permissive license. Swift Package
  Manager resolves the version pinned in `Package.resolved`. Packaging includes
  Sparkle's own license from the downloaded framework. See
  https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE.
- **Memory Pack** provides local conversation exports. Its Rust source is in
  https://github.com/Significant-Hobbies/chatgpt-memory-insights/tree/main/packer
  under MIT. The compatible source is included in `Vendor/MemoryPack`, with
  its upstream origin and local changes documented in `UPSTREAM.md`.
  `prepare-memory-pack.py` collects the helper's license and the
  notices of its Cargo dependencies into the distributed app.
- **ClaudeOfficial.png** is Anthropic's provider artwork, obtained from its
  official press kit: https://www.anthropic.com/press-kit. It is excluded from
  StorageDaddy's MIT grant. Claude and Anthropic marks belong to Anthropic PBC.
- **ChatGPTOfficial.png** is OpenAI's provider artwork, obtained from an
  installed, signed OpenAI application. It is excluded from StorageDaddy's MIT
  grant. ChatGPT and OpenAI marks belong to OpenAI. Use is subject to
  https://openai.com/brand/. The historical acquisition details and image
  hashes are recorded in `Assets/ProviderIcons-provenance.json`.
- StorageDaddy's app icon and doodle illustrations were generated for this
  project with OpenAI image generation. They are distinct from the provider
  artwork above. No third-party endorsement is implied.

Mole, dua and dust informed implementation research. Their code is not bundled
as the scanner. DiskBuddy was a functional reference, not a source of copied
branding or application code. StorageDaddy is not affiliated with these tools
or with Anthropic or OpenAI.
