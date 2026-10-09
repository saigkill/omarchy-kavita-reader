.pragma library

// Session-local, non-reactive state shared by the panel views. Anything the
// service owns (URL, token, lists) lives in Service.qml; this is only the
// panel's cursor into the library so a view switch can rebuild itself.
var DEFAULT_URL = "http://localhost:5000"

var state = {
  currentBook: null,
  currentPath: ""
}
