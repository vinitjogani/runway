// Core Foundation for the system frameworks that re-export it (CoreServices,
// ApplicationServices, Carbon, IOKit…). The names live in RunwayFoundation
// (as Foundation re-exports Core Foundation on the Mac); one definition, so
// importing several frameworks never makes a name ambiguous.

@_exported import Foundation
@_exported import RunwayFoundation
