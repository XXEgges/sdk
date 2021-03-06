// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:html';

import 'package:analysis_server/src/edit/nnbd_migration/web/edit_details.dart';
import 'package:analysis_server/src/edit/nnbd_migration/web/file_details.dart';
import 'package:analysis_server/src/edit/nnbd_migration/web/navigation_tree.dart';
import 'package:path/path.dart' as _p;

import 'highlight_js.dart';

// TODO(devoncarew): Fix the issue where we can't load source maps.

// TODO(devoncarew): Include a favicon.

void main() {
  document.addEventListener('DOMContentLoaded', (event) {
    var path = window.location.pathname;
    var offset = getOffset(window.location.href);
    var lineNumber = getLine(window.location.href);
    loadNavigationTree();
    if (path != '/' && path != rootPath) {
      // TODO(srawlins): replaceState?
      loadFile(path, offset, lineNumber, true, callback: () {
        pushState(path, offset, lineNumber);
      });
    }

    final applyMigrationButton = document.querySelector('.apply-migration');
    applyMigrationButton.onClick.listen((event) {
      if (window.confirm(
          "This will apply the changes you've previewed to your working "
          'directory. It is recommended you commit any changes you made before '
          'doing this.')) {
        doPost('/apply-migration').then((xhr) {
          document.body.classes
            ..remove('proposed')
            ..add('applied');
        }).catchError((e, st) {
          logError('apply migration error: $e', st);

          window.alert('Could not apply migration ($e).');
        });
      }
    });

    final rerunMigrationButton = document.querySelector('.rerun-migration');
    rerunMigrationButton.onClick.listen((event) async {
      try {
        document.body.classes..add('rerunning');
        await doPost('/rerun-migration');
        window.location.reload();
      } catch (e, st) {
        logError('rerun migration: $e', st);

        window.alert('Failed to rerun migration: $e.');
      } finally {
        document.body.classes.remove('rerunning');
      }
    });
  });

  window.addEventListener('popstate', (event) {
    var path = window.location.pathname;
    var offset = getOffset(window.location.href);
    var lineNumber = getLine(window.location.href);
    if (path.length > 1) {
      loadFile(path, offset, lineNumber, false);
    } else {
      // Blank out the page, for the index screen.
      writeCodeAndRegions(path, FileDetails.empty(), true);
      updatePage('&nbsp;', null);
    }
  });
}

/// Returns the "authToken" query parameter value of the current location.
// TODO(srawlins): This feels a little fragile, as the user can accidentally
//  change/remove this text, and break their session. Normally auth tokens are
//  stored in cookies, but there is no authentication step during which the
//  server would attach such a token to cookies. We could do a little step where
//  the first request to the server with the token is considered
//  "authentication", and we subsequently store the token in cookies thereafter.
final String authToken =
    Uri.parse(window.location.href).queryParameters['authToken'];

final Element editListElement =
    document.querySelector('.edit-list .panel-content');

final Element editPanel = document.querySelector('.edit-panel .panel-content');

final Element footerPanel = document.querySelector('footer');

final Element headerPanel = document.querySelector('header');

final Element unitName = document.querySelector('#unit-name');

String get rootPath => querySelector('.root').text.trim();

void addArrowClickHandler(Element arrow) {
  var childList = (arrow.parentNode as Element).querySelector(':scope > ul');
  // Animating height from "auto" to "0" is not supported by CSS [1], so all we
  // have are hacks. The `* 2` allows for events in which the list grows in
  // height when resized, with additional text wrapping.
  // [1] https://css-tricks.com/using-css-transitions-auto-dimensions/
  childList.style.maxHeight = '${childList.offsetHeight * 2}px';
  arrow.onClick.listen((MouseEvent event) {
    if (!childList.classes.contains('collapsed')) {
      childList.classes.add('collapsed');
      arrow.classes.add('collapsed');
    } else {
      childList.classes.remove('collapsed');
      arrow.classes.remove('collapsed');
    }
  });
}

void addClickHandlers(String selector, bool clearEditDetails) {
  var parentElement = document.querySelector(selector);

  // Add navigation handlers for navigation links in the source code.
  List<Element> navLinks = parentElement.querySelectorAll('.nav-link');
  navLinks.forEach((link) {
    link.onClick.listen((event) {
      var tableElement = document.querySelector('table[data-path]');
      var parentPath = tableElement.dataset['path'];
      handleNavLinkClick(event, clearEditDetails, relativeTo: parentPath);
    });
  });

  List<Element> regions = parentElement.querySelectorAll('.region');
  if (regions.isNotEmpty) {
    var table = parentElement.querySelector('table[data-path]');
    var path = table.dataset['path'];
    regions.forEach((Element anchor) {
      anchor.onClick.listen((event) {
        var offset = int.parse(anchor.dataset['offset']);
        var line = int.parse(anchor.dataset['line']);
        loadAndPopulateEditDetails(path, offset, line);
      });
    });
  }

  List<Element> postLinks = parentElement.querySelectorAll('.post-link');
  postLinks.forEach((link) {
    link.onClick.listen(handlePostLinkClick);
  });
}

Future<HttpRequest> doGet(String path,
        {Map<String, String> queryParameters = const {}}) =>
    HttpRequest.request(pathWithQueryParameters(path, queryParameters),
        requestHeaders: {'Content-Type': 'application/json; charset=UTF-8'});

Future<HttpRequest> doPost(String path) => HttpRequest.request(
      pathWithQueryParameters(path, {}),
      method: 'POST',
      requestHeaders: {'Content-Type': 'application/json; charset=UTF-8'},
    ).then((HttpRequest xhr) {
      if (xhr.status == 200) {
        // Request OK.
        return xhr;
      } else {
        throw 'Request failed; status of ${xhr.status}';
      }
    });

int getLine(String location) {
  var str = Uri.parse(location).queryParameters['line'];
  return str == null ? null : int.tryParse(str);
}

int getOffset(String location) {
  var str = Uri.parse(location).queryParameters['offset'];
  return str == null ? null : int.tryParse(str);
}

void handleNavLinkClick(
  MouseEvent event,
  bool clearEditDetails, {
  String relativeTo,
}) {
  Element target = event.currentTarget;
  event.preventDefault();

  var location = target.getAttribute('href');
  var path = location;
  if (path.contains('?')) {
    path = path.substring(0, path.indexOf('?'));
  }
  // Fix-up the path - it might be relative.
  if (relativeTo != null) {
    path = _p.normalize(_p.join(_p.dirname(relativeTo), path));
  }

  var offset = getOffset(location);
  var lineNumber = getLine(location);

  if (offset != null) {
    navigate(path, offset, lineNumber, clearEditDetails, callback: () {
      pushState(path, offset, lineNumber);
    });
  } else {
    navigate(path, null, null, clearEditDetails, callback: () {
      pushState(path, null, null);
    });
  }
}

void handlePostLinkClick(MouseEvent event) async {
  var path = (event.currentTarget as Element).getAttribute('href');

  // Don't navigate on link click.
  event.preventDefault();

  try {
    // Directing the server to produce an edit; request it, then do work with the
    // response.
    await doPost(path);
    // TODO(mfairhurst): Only refresh the regions/dart code, not the window.
    (document.window.location as Location).reload();
  } catch (e, st) {
    logError('handlePostLinkClick: $e', st);

    window.alert('Could not load $path ($e).');
  }
}

void highlightAllCode() {
  document.querySelectorAll('.code').forEach((Element block) {
    hljs.highlightBlock(block);
  });
}

/// Loads the explanation for [region], into the ".panel-content" div.
void loadAndPopulateEditDetails(String path, int offset, int line) {
  // Request the region, then do work with the response.
  doGet(path, queryParameters: {'region': 'region', 'offset': '$offset'})
      .then((HttpRequest xhr) {
    if (xhr.status == 200) {
      var response = EditDetails.fromJson(jsonDecode(xhr.responseText));
      populateEditDetails(response);
      pushState(path, offset, line);
      addClickHandlers('.edit-panel .panel-content', false);
    } else {
      window.alert('Request failed; status of ${xhr.status}');
    }
  }).catchError((e, st) {
    logError('loadRegionExplanation: $e', st);

    window.alert('Could not load $path ($e).');
  });
}

/// Load the file at [path] from the server, optionally scrolling [offset] into
/// view.
void loadFile(
  String path,
  int offset,
  int line,
  bool clearEditDetails, {
  VoidCallback callback,
}) {
  // Handle the case where we're requesting a directory.
  if (!path.endsWith('.dart')) {
    writeCodeAndRegions(path, FileDetails.empty(), clearEditDetails);
    updatePage(path);
    if (callback != null) {
      callback();
    }

    return;
  }

  // Navigating to another file; request it, then do work with the response.
  doGet(path, queryParameters: {'inline': 'true'}).then((HttpRequest xhr) {
    if (xhr.status == 200) {
      Map<String, dynamic> response = jsonDecode(xhr.responseText);
      writeCodeAndRegions(
          path, FileDetails.fromJson(response), clearEditDetails);
      maybeScrollToAndHighlight(offset, line);
      var filePathPart =
          path.contains('?') ? path.substring(0, path.indexOf('?')) : path;
      updatePage(filePathPart, offset);
      if (callback != null) {
        callback();
      }
    } else {
      window.alert('Request failed; status of ${xhr.status}');
    }
  }).catchError((e, st) {
    logError('loadFile: $e', st);

    window.alert('Could not load $path ($e).');
  });
}

/// Load the navigation tree into the ".nav-tree" div.
void loadNavigationTree() {
  var path = '/_preview/navigationTree.json';

  // Request the navigation tree, then do work with the response.
  doGet(path).then((HttpRequest xhr) {
    if (xhr.status == 200) {
      dynamic response = jsonDecode(xhr.responseText);
      var navTree = document.querySelector('.nav-tree');
      navTree.innerHtml = '';
      writeNavigationSubtree(
          navTree, NavigationTreeNode.listFromJson(response));
    } else {
      window.alert('Request failed; status of ${xhr.status}');
    }
  }).catchError((e, st) {
    logError('loadNavigationTree: $e', st);

    window.alert('Could not load $path ($e).');
  });
}

void logError(e, st) {
  window.console.error('$e');
  window.console.error('$st');
}

/// Scroll an element into view if it is not visible.
void maybeScrollIntoView(Element element) {
  var rect = element.getBoundingClientRect();
  // A line of text in the code view is 14px high. Including it here means we
  // only choose to _not_ scroll a line of code into view if the entire line is
  // visible.
  var lineHeight = 14;
  var visibleCeiling = headerPanel.offsetHeight + lineHeight;
  var visibleFloor =
      window.innerHeight - (footerPanel.offsetHeight + lineHeight);
  if (rect.bottom > visibleFloor) {
    element.scrollIntoView();
  } else if (rect.top < visibleCeiling) {
    element.scrollIntoView();
  }
}

/// Scroll target with id [offset] into view if it is not currently in view.
///
/// If [offset] is null, instead scroll the "unit-name" header, at the top of
/// the page, into view.
///
/// Also add the "target" class, highlighting the target. Also add the
/// "highlight" class to the entire line on which the target lies.
void maybeScrollToAndHighlight(int offset, int lineNumber) {
  Element target;
  Element line;

  if (offset != null) {
    target = document.getElementById('o$offset');
    line = document.querySelector('.line-$lineNumber');
    if (target != null) {
      maybeScrollIntoView(target);
      target.classes.add('target');
    } else if (line != null) {
      // If the target doesn't exist, but the line does, scroll that into view
      // instead.
      maybeScrollIntoView(line.parent);
    }
    if (line != null) {
      (line.parentNode as Element).classes.add('highlight');
    }
  } else {
    // If no offset is given, this is likely a navigation link, and we need to
    // scroll back to the top of the page.
    maybeScrollIntoView(unitName);
  }
}

/// Navigate to [path] and optionally scroll [offset] into view.
///
/// If [callback] is present, it will be called after the server response has
/// been processed, and the content has been updated on the page.
void navigate(
  String path,
  int offset,
  int lineNumber,
  bool clearEditDetails, {
  VoidCallback callback,
}) {
  var currentOffset = getOffset(window.location.href);
  var currentLineNumber = getLine(window.location.href);
  removeHighlight(currentOffset, currentLineNumber);
  if (path == window.location.pathname) {
    // Navigating to same file; just scroll into view.
    maybeScrollToAndHighlight(offset, lineNumber);
    if (callback != null) {
      callback();
    }
  } else {
    loadFile(path, offset, lineNumber, clearEditDetails, callback: callback);
  }
}

/// Returns [path], which may include query parameters, with a new path which
/// adds (or replaces) parameters from [queryParameters].
///
/// Additionally, the "authToken" parameter will be added with the authToken
/// found in the current location.
String pathWithQueryParameters(
    String path, Map<String, String> queryParameters) {
  var uri = Uri.parse(path);
  var mergedQueryParameters = {
    ...uri.queryParameters,
    ...queryParameters,
    'authToken': authToken
  };
  return uri.replace(queryParameters: mergedQueryParameters).toString();
}

String pluralize(int count, String single, {String multiple}) {
  return count == 1 ? single : (multiple ?? '${single}s');
}

void populateEditDetails([EditDetails response]) {
  // Clear out any current edit details.
  editPanel.innerHtml = '';
  if (response == null) {
    Element p = editPanel.append(ParagraphElement()
      ..text = 'See details about a proposed edit.'
      ..classes = ['placeholder']);
    p.scrollIntoView();
    return;
  }

  var filePath = response.path;
  var parentDirectory = _p.dirname(filePath);

  // 'Changed ... at foo.dart:12.'
  var explanationMessage = response.explanation;
  var relPath = _p.relative(filePath, from: rootPath);
  var line = response.line;
  Element explanation = editPanel.append(document.createElement('p'));
  explanation.append(Text('$explanationMessage at $relPath:$line.'));
  explanation.scrollIntoView();
  _populateEditTraces(response, editPanel, parentDirectory);
  _populateEditLinks(response, editPanel);
}

/// Write the contents of the Edit List, from JSON data [editListData].
void populateProposedEdits(
    String path, Map<String, List<EditListItem>> edits, bool clearEditDetails) {
  editListElement.innerHtml = '';

  var editCount = edits.length;
  if (editCount == 0) {
    Element p = editListElement.append(document.createElement('p'));
    p.append(Text('No proposed edits'));
  } else {
    for (var entry in edits.entries) {
      Element p = editListElement.append(document.createElement('p'));
      p.append(Text('${entry.key}:'));

      Element list = editListElement.append(document.createElement('ul'));
      for (var edit in entry.value) {
        Element item = list.append(document.createElement('li'));
        item.classes.add('edit');
        AnchorElement anchor = item.append(document.createElement('a'));
        anchor.classes.add('edit-link');
        var offset = edit.offset;
        anchor.dataset['offset'] = '$offset';
        var line = edit.line;
        anchor.dataset['line'] = '$line';
        anchor.append(Text('line $line'));
        anchor.onClick.listen((MouseEvent event) {
          navigate(window.location.pathname, offset, line, true, callback: () {
            pushState(window.location.pathname, offset, line);
          });
          loadAndPopulateEditDetails(path, offset, line);
        });
        item.append(Text(': ${edit.explanation}'));
      }
    }
  }

  if (clearEditDetails) {
    populateEditDetails();
  }
}

void pushState(String path, int offset, int line) {
  var uri = Uri.parse('${window.location.origin}$path');

  var params = {
    if (offset != null) 'offset': '$offset',
    if (line != null) 'line': '$line',
    'authToken': authToken,
  };

  uri = uri.replace(queryParameters: params);
  window.history.pushState({}, '', uri.toString());
}

/// If [path] lies within [root], return the relative path of [path] from [root].
/// Otherwise, return [path].
String relativePath(String path) {
  var root = querySelector('.root').text + '/';
  if (path.startsWith(root)) {
    return path.substring(root.length);
  } else {
    return path;
  }
}

/// Remove highlighting from [offset].
void removeHighlight(int offset, int lineNumber) {
  if (offset != null) {
    var anchor = document.getElementById('o$offset');
    if (anchor != null) {
      anchor.classes.remove('target');
    }
  }
  if (lineNumber != null) {
    var line = document.querySelector('.line-$lineNumber');
    if (line != null) {
      line.parent.classes.remove('highlight');
    }
  }
}

/// Update the heading and navigation links.
///
/// Call this after updating page content on a navigation.
void updatePage(String path, [int offset]) {
  path = relativePath(path);
  // Update page heading.
  unitName.text = path;
  // Update navigation styles.
  document.querySelectorAll('.nav-panel .nav-link').forEach((Element link) {
    var name = link.dataset['name'];
    if (name == path) {
      link.classes.add('selected-file');
    } else {
      link.classes.remove('selected-file');
    }
  });
}

/// Load data from [data] into the .code and the .regions divs.
void writeCodeAndRegions(String path, FileDetails data, bool clearEditDetails) {
  var regionsElement = document.querySelector('.regions');
  var codeElement = document.querySelector('.code');

  _PermissiveNodeValidator.setInnerHtml(regionsElement, data.regions);
  _PermissiveNodeValidator.setInnerHtml(codeElement, data.navigationContent);
  populateProposedEdits(path, data.edits, clearEditDetails);

  highlightAllCode();
  addClickHandlers('.code', true);
  addClickHandlers('.regions', true);
}

void writeNavigationSubtree(
    Element parentElement, List<NavigationTreeNode> tree) {
  Element ul = parentElement.append(document.createElement('ul'));
  for (var entity in tree) {
    Element li = ul.append(document.createElement('li'));
    if (entity.type == NavigationTreeNodeType.directory) {
      li.classes.add('dir');
      Element arrow = li.append(document.createElement('span'));
      arrow.classes.add('arrow');
      arrow.innerHtml = '&#x25BC;';
      Element icon = li.append(document.createElement('span'));
      icon.innerHtml = '&#x1F4C1;';
      li.append(Text(entity.name));
      writeNavigationSubtree(li, entity.subtree);
      addArrowClickHandler(arrow);
    } else {
      li.innerHtml = '&#x1F4C4;';
      Element a = li.append(document.createElement('a'));
      a.classes.add('nav-link');
      a.dataset['name'] = entity.path;
      a.setAttribute('href', entity.href);
      a.append(Text(entity.name));
      a.onClick.listen((MouseEvent event) => handleNavLinkClick(event, true));
      var editCount = entity.editCount;
      if (editCount > 0) {
        Element editsBadge = li.append(document.createElement('span'));
        editsBadge.classes.add('edit-count');
        editsBadge.setAttribute(
            'title', '$editCount ${pluralize(editCount, 'edit')}');
        editsBadge.append(Text(editCount.toString()));
      }
    }
  }
}

AnchorElement _aElementForLink(TargetLink link, String parentDirectory) {
  var targetLine = link.line;
  AnchorElement a = document.createElement('a');
  a.append(Text('${link.path}:$targetLine'));

  var relLink = link.href;
  var fullPath = _p.normalize(_p.join(parentDirectory, relLink));

  a.setAttribute('href', fullPath);
  a.classes.add('nav-link');
  return a;
}

void _populateEditLinks(EditDetails response, Element editPanel) {
  if (response.edits != null) {
    Element editParagraph = editPanel.append(document.createElement('p'));
    for (var edit in response.edits) {
      Element a = editParagraph.append(document.createElement('a'));
      a.append(Text(edit.description));
      a.setAttribute('href', edit.href);
      a.classes = ['post-link', 'before-apply'];
    }
  }
}

void _populateEditTraces(
    EditDetails response, Element editPanel, String parentDirectory) {
  for (var trace in response.traces) {
    var traceParagraph =
        editPanel.append(document.createElement('p')..classes = ['trace']);
    traceParagraph.append(document.createElement('span')
      ..classes = ['type-description']
      ..append(Text(trace.description)));
    traceParagraph.append(Text(':'));
    var ul = traceParagraph
        .append(document.createElement('ul')..classes = ['trace']);
    for (var entry in trace.entries) {
      Element li =
          ul.append(document.createElement('li')..innerHtml = '&#x274F; ');
      li.append(document.createElement('span')
        ..classes = ['function']
        ..appendTextWithBreaks(entry.function ?? 'unknown'));
      var link = entry.link;
      if (link != null) {
        li.append(Text(' ('));
        li.append(_aElementForLink(link, parentDirectory));
        li.append(Text(')'));
      }
      li.append(Text(': '));
      li.appendTextWithBreaks(entry.description ?? 'unknown');
    }
  }
}

class _PermissiveNodeValidator implements NodeValidator {
  static _PermissiveNodeValidator instance = _PermissiveNodeValidator();

  @override
  bool allowsAttribute(Element element, String attributeName, String value) {
    return true;
  }

  @override
  bool allowsElement(Element element) {
    return true;
  }

  static void setInnerHtml(Element element, String html) {
    element.setInnerHtml(html, validator: instance);
  }
}

/// An extension on Element that fits into cascades.
extension on Element {
  /// Append [text] to this, inserting a word break before each '.' character.
  void appendTextWithBreaks(String text) {
    var textParts = text.split('.');
    append(Text(textParts.first));
    for (var substring in textParts.skip(1)) {
      // Replace the '.' with a zero-width space and a '.'.
      appendHtml('&#8203;.');
      append(Text(substring));
    }
  }
}
