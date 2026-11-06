.pragma library

// Lets the bar widget find the one running service. Omarchy starts Service.qml
// under whichever bar is active, but only its built-in bar gives widgets a way
// to reach it. A replacement bar (Islands, or a clone of the stock bar) hands
// them a shell whose serviceFor() always returns null, by design, so that no
// bar can ask Omarchy for another plugin's live service.
//
// This goes around that on purpose, for this plugin's own widget only. It is
// not a security boundary: anything else in the shell's process can import
// this file too, as it can already reach the rest of the shell's objects.
//
// .pragma library makes this one shared copy, however many files import it.

var service = null

function register(instance) {
  service = instance
}

// Clears only the service going away, so a late one cannot remove the service
// that replaced it during a plugin reload.
function unregister(instance) {
  if (service === instance) service = null
}

function current() {
  return service
}
