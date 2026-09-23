ContextDaddy 0.1.0
==================

Apple silicon Mac · macOS 14 Sonoma or later

Install
-------
Drag ContextDaddy to Applications, eject this disk image, then open the app
from Applications. ContextDaddy is a read-only local view of coding-agent
skills, project context, usage history, and available OpenTelemetry signals.

Start with Usage for local history and provider allowance. Skills explains
which definitions each supported agent can discover and invoke. Projects shows
discovered context files; it does not claim those files were loaded into a
live prompt. OpenTelemetry shows only verified signals from a compatible
local collector. Files & diagnostics holds raw inventory and configuration
findings. Missing sources are shown as unavailable, not as zero activity.

Privacy and limitations
-----------------------
The app reads bounded local metadata and configuration structure, but does not
copy prompt bodies, tool arguments, or credential values into its dashboards.
An explicit document preview opens the selected eligible text file. The
bundled ccusage helper reads local history offline. Provider allowance checks
use installed provider CLIs only when requested or after you opt in to an
automatic check; local OpenTelemetry uses a loopback collector if available.
ContextDaddy does not measure internet bandwidth, and estimated token or
project values are labelled as such. It never edits agent configuration.

ContextDaddy includes ccusage under the MIT license; its acknowledgement and
license text are in CONTEXTDADDY_NOTICES.md inside the app bundle.
