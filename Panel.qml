import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Pdf
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Kavita reader panel: sign in, browse libraries -> series -> books, and read
// the downloaded book inline (EPUB converted to PDF, PDF via QtQuick.Pdf,
// CBZ/CBR as page images). The session and all HTTP live in Service.qml; this
// panel is a view over the service handed down by the bar widget.
Panel {
  id: root
  moduleName: "saigkill.kavita-reader"
  ipcTarget: "saigkill.kavita-reader"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var svc: hostWidget ? hostWidget.svc : null

  property string readerMessage: ""
  property var cbzImages: []
  property int cbzIndex: 0
  property var allSeries: []

  readonly property color contentForeground: bar ? bar.barForeground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool readerOpen: readerStack.currentIndex === 2 && root.cbzImages.length > 0

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  function fill(model, list) {
    model.clear()
    for (var i = 0; i < (list ? list.length : 0); i++) model.append(list[i])
  }

  // The series list is filtered in the panel: every series of the selected
  // library is loaded at once, so a case-insensitive substring match on the
  // title is enough and needs no extra request.
  function applySeriesFilter() {
    var query = String(seriesSearch.text || "").trim().toLowerCase()
    seriesModel.clear()
    for (var i = 0; i < root.allSeries.length; i++) {
      var series = root.allSeries[i]
      if (query === "" || String(series.name || "").toLowerCase().indexOf(query) !== -1)
        seriesModel.append(series)
    }
  }

  function openBook(book) {
    if (!book) return
    Model.state.currentBook = book
    bookTitle.text = book.name
    var fname = book.path || (book.name + "." + String(book.format || "").toLowerCase())
    if (root.svc) root.svc.downloadBook(book.id, fname)
  }

  function openDownloaded(path) {
    Model.state.currentPath = path
    var book = Model.state.currentBook
    if (!book) return
    var fmt = String(book.format || "").toUpperCase()
    if (fmt === "PDF") {
      root.cbzImages = []
      pdfDoc.source = "file://" + path
      readerStack.currentIndex = 1
      stack.currentIndex = 2
    } else if (fmt === "CBZ" || fmt === "CBR") {
      root.cbzImages = []
      root.cbzIndex = 0
      if (root.svc) {
        if (fmt === "CBZ") root.svc.unpackCbz(path)
        else root.svc.unpackCbr(path)
      }
      readerStack.currentIndex = 2
      stack.currentIndex = 2
    } else if (fmt === "IMAGE") {
      // A loose image file is its own single page.
      root.cbzImages = [path]
      root.cbzIndex = 0
      readerStack.currentIndex = 2
      stack.currentIndex = 2
    } else {
      // EPUB and other ebook formats: convert to PDF first (Quickshell cannot
      // host a web engine), then show the result in the PDF viewer.
      root.readerMessage = "EPUB wird konvertiert…"
      pdfDoc.source = ""
      readerStack.currentIndex = 0
      stack.currentIndex = 2
      if (root.svc) root.svc.convertEpub(path)
    }
  }

  // The session may already be restored from disk before this panel exists,
  // in which case onLoggedInChanged never fires for it.
  Component.onCompleted: {
    if (root.svc && root.svc.loggedIn) {
      stack.currentIndex = 1
      root.svc.getLibraries()
    }
  }

  Connections {
    target: root.svc
    enabled: root.svc !== null

    function onLoggedInChanged() {
      if (root.svc && root.svc.loggedIn) {
        stack.currentIndex = 1
        root.svc.getLibraries()
      } else {
        stack.currentIndex = 0
      }
    }
    function onLibrariesLoaded(list) { root.fill(libModel, list) }
    function onSeriesLoaded(list) {
      root.allSeries = list || []
      root.applySeriesFilter()
    }
    function onBooksLoaded(list) { root.fill(booksModel, list) }
    function onBookDownloaded(path) { root.openDownloaded(path) }
    function onEpubConverted(pdfPath) {
      root.readerMessage = ""
      Model.state.currentPath = pdfPath
      pdfDoc.source = "file://" + pdfPath
      readerStack.currentIndex = 1
    }
    function onCbzUnpacked(dir, images) {
      root.cbzImages = images
      root.cbzIndex = 0
    }
    function onErrorOccurred(message) { errorText.text = message; root.readerMessage = message }
  }

  ListModel { id: libModel }
  ListModel { id: seriesModel }
  ListModel { id: booksModel }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(1000))
    contentHeight: panel.fittedContentHeight(Style.space(640), Style.space(700))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: urlField.activeFocus || userField.activeFocus || passField.activeFocus || seriesSearch.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dx > 0 && root.readerOpen) root.cbzIndex = Math.min(root.cbzImages.length - 1, root.cbzIndex + 1)
        else if (dx < 0 && root.readerOpen) root.cbzIndex = Math.max(0, root.cbzIndex - 1)
      }

      ColumnLayout {
        anchors.fill: parent
        spacing: Style.space(8)

        RowLayout {
          Layout.fillWidth: true

          Text {
            text: "KAVITA READER"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.bold: true
          }
          Item { Layout.fillWidth: true }
          Button {
            text: "Schließen"
            onClicked: root.close()
          }
        }

        StackLayout {
          id: stack
          Layout.fillWidth: true
          Layout.fillHeight: true
          currentIndex: 0

          // ---- login ------------------------------------------------------
          ColumnLayout {
            spacing: Style.space(8)

            Label { text: "Kavita URL"; color: root.contentForeground }
            TextField {
              id: urlField
              Layout.fillWidth: true
              text: (root.svc && root.svc.kavitaUrl) ? root.svc.kavitaUrl : Model.DEFAULT_URL
            }
            Label { text: "Benutzername"; color: root.contentForeground }
            TextField { id: userField; Layout.fillWidth: true; text: root.svc ? root.svc.username : "" }
            Label { text: "Passwort"; color: root.contentForeground }
            TextField { id: passField; Layout.fillWidth: true; echoMode: TextInput.Password }
            Button {
              text: "Login"
              onClicked: if (root.svc) root.svc.login(urlField.text, userField.text, passField.text)
            }
            Label {
              id: errorText
              color: "#ff6b6b"
              wrapMode: Text.Wrap
              Layout.fillWidth: true
            }
          }

          // ---- browser ----------------------------------------------------
          RowLayout {
            spacing: Style.space(8)

            ColumnLayout {
              Layout.preferredWidth: Style.space(200)

              Label { text: "Bibliotheken"; color: root.contentForeground }
              ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                model: libModel
                delegate: ItemDelegate {
                  width: ListView.view.width
                  text: model.name
                  onClicked: {
                    seriesSearch.text = ""
                    if (root.svc) root.svc.getSeries(model.id)
                  }
                }
              }
              Button { text: "Aktualisieren"; onClicked: if (root.svc) root.svc.getLibraries() }
            }

            ColumnLayout {
              Layout.preferredWidth: Style.space(260)

              Label { text: "Serien"; color: root.contentForeground }
              TextField {
                id: seriesSearch
                Layout.fillWidth: true
                placeholderText: "Serie suchen…"
                onTextChanged: root.applySeriesFilter()
              }
              ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                model: seriesModel
                delegate: ItemDelegate {
                  width: ListView.view.width
                  text: model.name
                  onClicked: if (root.svc) root.svc.getBooks(model.id)
                }
              }
            }

            ColumnLayout {
              Layout.fillWidth: true

              Label { text: "Bücher"; color: root.contentForeground }
              ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                model: booksModel
                delegate: ItemDelegate {
                  width: ListView.view.width
                  text: model.name + " (" + (model.format || "") + ")"
                  onClicked: root.openBook(model)
                }
              }
            }
          }

          // ---- reader -----------------------------------------------------
          ColumnLayout {
            spacing: Style.space(8)

            RowLayout {
              Layout.fillWidth: true

              Button { text: "← Bibliothek"; onClicked: stack.currentIndex = 1 }
              Label {
                id: bookTitle
                color: root.contentForeground
                elide: Text.ElideRight
                Layout.fillWidth: true
              }
              Button {
                visible: root.readerOpen && root.cbzImages.length > 1
                text: "← Vorige"
                onClicked: root.cbzIndex = Math.max(0, root.cbzIndex - 1)
              }
              Label {
                visible: root.readerOpen
                text: (root.cbzIndex + 1) + "/" + root.cbzImages.length
                color: root.contentForeground
              }
              Button {
                visible: root.readerOpen && root.cbzImages.length > 1
                text: "Nächste →"
                onClicked: root.cbzIndex = Math.min(root.cbzImages.length - 1, root.cbzIndex + 1)
              }
            }

            // Non-visual document holder; it must stay outside readerStack so
            // the stack indices line up: 0 message, 1 PDF, 2 CBZ pages.
            PdfDocument {
              id: pdfDoc
            }

            StackLayout {
              id: readerStack
              Layout.fillWidth: true
              Layout.fillHeight: true
              currentIndex: 0

              Item {
                Label {
                  anchors.centerIn: parent
                  width: parent.width * 0.8
                  horizontalAlignment: Text.AlignHCenter
                  wrapMode: Text.Wrap
                  text: root.readerMessage
                  color: root.contentForeground
                }
              }

              PdfMultiPageView {
                id: pdfView
                Layout.fillWidth: true
                Layout.fillHeight: true
                document: pdfDoc

                // Keep the rendered pages inside the panel: clip removes the
                // spill above/below the window, and fitWidth scales every page
                // to the view width so only vertical scrolling remains.
                clip: true

                function fitWidth() {
                  if (!pdfDoc || pdfDoc.status !== PdfDocument.Ready || width <= 0)
                    return
                  scaleToWidth(width, height)
                }

                Component.onCompleted: fitWidth()
                onWidthChanged: fitWidth()
                onHeightChanged: fitWidth()

                Connections {
                  target: pdfDoc
                  function onStatusChanged() { pdfView.fitWidth() }
                }
              }

              // Fit the page to the panel width and let the Flickable scroll it
              // vertically. The image must size against the Flickable viewport
              // and not against its own parent: contentHeight follows the image
              // height, so sizing the image from its parent would close a
              // binding loop and collapse the image to zero (blank reader).
              Flickable {
                id: cbzView
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: width
                contentHeight: cbzImg.height
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Image {
                  id: cbzImg
                  asynchronous: true
                  smooth: true
                  fillMode: Image.PreserveAspectFit
                  width: cbzView.width
                  height: sourceSize.width > 0
                    ? cbzView.width * sourceSize.height / sourceSize.width
                    : 0
                  source: root.cbzImages.length > 0 ? "file://" + root.cbzImages[root.cbzIndex] : ""
                }
              }
            }
          }
        }
      }
    }
  }
}
