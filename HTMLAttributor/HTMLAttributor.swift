//
//  HTMLAttributor.Swift
//  HTMLAttributor
//
//  Created by Michael on 8/9/16.
//  Copyright © 2016 Michael Nisi. All rights reserved.
//

import Foundation
import UIKit

// TODO: Rename framework to HTML
// TODO: Rename GitHub repo to html

// MARK: API

public protocol HTMLParsing {
  
  // MARK: Creating a tree from HTML
  
  func parse(html: String) throws -> Node
  
  // MARK: Transforming the tree to strings
  
  func string(tree: Node) throws -> String
  
  func attributedString(
    tree: Node,
    styles: [String: [String : AnyObject]]
  ) throws -> NSAttributedString
}

// MARK: - DOM

public struct ElementData {
  let tagName: String
  let attributes: [String : String]
}

public enum NodeType {
  case Text(String)
  case Element(ElementData)
}

public final class Node {
  var children: [Node]
  let type: NodeType
  internal let uid: UInt

  init(uid: UInt, type: NodeType, children: [Node] = [Node]()) {
    self.uid = uid
    self.type = type
    self.children = children
  }

  func append(node: Node) {
    children.append(node)
  }
}

extension Node: CustomStringConvertible {
  public var description: String {
    get {
      func desc() -> String {
        switch type {
        case .Element(let data):
          return "\(uid): \(data.tagName)"
        case .Text(let text):
          return "\(uid): \(text)"
        }
      }
      return children.reduce(desc()) { acc, child in
        "\(acc) \(child.description)"
      }
    }
  }
}

public func ==(lhs: Node, rhs: Node) -> Bool {
  return lhs.uid == rhs.uid
}

extension Node: Hashable {
  public var hashValue: Int {
    return uid.hashValue
  }
}

func allNodes(root: Node) -> [Node] {
  return root.children.reduce([root]) { acc, node in
    acc + allNodes(node)
  }
}

func candidate(root: Node, node: Node) -> Node {
  func fallback() -> Node {
    let nodes = allNodes(root)
    let p = parent(node, nodes: nodes)
    return candidate(root, node: p)
  }
  switch node.type {
  case .Element(let data):
    if data.tagName == "br" {
      return fallback()
    }
  case .Text:
    return fallback()
  }
  return node
}

func parent(node: Node, nodes: [Node]) -> Node {
  assert(!nodes.isEmpty, "no candidates")
  let parents = nodes.filter {
    $0.children.contains { $0 == node }
  }
  assert(!parents.isEmpty, "\(node.uid) is an orphan")
  assert(parents.count == 1, "multiple parents")

  let p = parents.first!
  
  switch p.type {
  case.Element(let data):
    assert(data.tagName != "br", "invalid parent: br")
  case .Text:
    fatalError("invalid parent: text node")
  }
  
  return p
}

// MARK: Parser

private final class ParserDelegate: NSObject, NSXMLParserDelegate {

  // MARK: State

  // The root node of our document.
  var root: Node!

  // The current node in the tree while parsing.
  private var current: Node!
  
  // A count of the encountered nodes.
  private var count: UInt = 0
  
  func uid() -> UInt {
    count += 1
    return count
  }

  // MARK: API

  // Container to accumulate strings for text nodes. Should be set to `nil`
  // after all its content has been consumed.
  var text: String?

  private func consumeText() -> Bool {
    guard let t = text else {
      return false
    }
    let textNode = Node(uid: uid(), type: .Text(t))
    let p = candidate(root, node: current)
    p.append(textNode)
    text = nil
    return true
  }
  
  // MARK: NSXMLParserDelegate
  
  @objc private func parser(
    parser: NSXMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String : String]
  ) {
    let data = ElementData(tagName: elementName, attributes: attributeDict)
    let node = Node(uid: uid(), type: .Element(data))

    if elementName == "root" {
      root = node
    } else {
      assert(root != nil, "root cannot be nil")
      
      // When a new element starts, we have to make sure we have consumed all
      // previously accumulated text and begin a new string.
      consumeText()

      let p = candidate(root, node: current)
      p.append(node)
    }
    
    current = node
  }

  @objc private func parser(
    parser: NSXMLParser,
    foundCharacters string: String
  ) {
    text = (text ?? "") + string
  }

  @objc private func parser(
    parser: NSXMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    assert(root != nil, "root cannot be nil")
    
    consumeText()

    guard elementName != "root" else {
      return
    }

    let nodes = allNodes(root)
    let p = parent(current, nodes: nodes)
    current = p
 }

  @objc private func parserDidEndDocument(parser: NSXMLParser) {
    current = nil
    text = nil
  }
}

func nsRange(
  from range: Range<String.Index>,
  within string: String
) -> NSRange {
  let utf16view = string.utf16
  let from = String.UTF16View.Index(range.startIndex, within: utf16view)
  let to = String.UTF16View.Index(range.endIndex, within: utf16view)
  return NSMakeRange(utf16view.startIndex.distanceTo(from), from.distanceTo(to))
}

func trimLeft(string: String) -> String {
  if string.hasPrefix(" ") {
    let str = String(string.characters.dropFirst())
    return trimLeft(str)
  }
  return string
}

public class HTMLAttributor: HTMLParsing {
  private var delegate: ParserDelegate!
  
  public init() {}
  
  public func parse(html: String) throws -> Node {
    delegate = ParserDelegate()

    // Always adding a root node to ensure somewhat valid XML.
    let str = "<root>\(html)</root>"
    let data = str.dataUsingEncoding(NSUTF8StringEncoding)!

    let parser = NSXMLParser(data: data)
    parser.shouldProcessNamespaces = false
    parser.delegate = delegate

    guard parser.parse() else {
      throw parser.parserError!
    }
    
    return delegate.root
  }
  
  private struct TaggedRange {
    let tag: String
    let attributes: [String : String]?
    let range: NSRange
  }
  
  private struct StringOptions: OptionSetType {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }
    
    static let BracketLinks = StringOptions(rawValue: 1)
  }
  
  // TODO: Use paragraph styles for p tags
  
  private func taggedString(
    tree: Node,
    opts: StringOptions = StringOptions()
  ) throws -> (String, [TaggedRange]) {
    let nodes = allNodes(tree)
    
    var ranges = [TaggedRange]()
    
    let str = nodes.reduce("") { acc, node in
      switch node.type {
      case .Element(let data):
        
        // Prepending
        
        switch data.tagName {
        case "h1", "h2", "h3", "h4", "h5", "h6", "p", "ul", "ol":
          if acc.isEmpty || acc.hasSuffix("\n\n") {
            return acc
          }
          return "\(acc)\(acc.hasSuffix("\n") ? "\n" : "\n\n")"
        
        // Disallowing more than two consecutive line breaks, assuming we have 
        // no control over the HTML input. Deliberately done here, not in the 
        // parse phase, to keep the tree authentic.
          
        case "br":
          if acc.isEmpty || acc.hasSuffix("\n\n") {
            return acc
          }
          return "\(acc)\n"
        default: return acc
        }
      case .Text(let text):
        
        // Appending
        
        let trimmed = text.stringByTrimmingCharactersInSet(
          NSCharacterSet.newlineCharacterSet()
        )
        
        var tag: String? = nil
        var attributes: [String : String]? = nil
        
        let n: String = {
          let p = parent(node, nodes: nodes)
          switch p.type {
          case .Element(let data):
            
            tag = data.tagName
            attributes = data.attributes
            
            switch data.tagName {
            case "a":
              if opts.contains(.BracketLinks) {
                if let href = attributes!["href"] {
                  return " (\(href))"
                }
              }
              return ""
            case "h1", "h2", "h3", "h4", "h5", "h6", "p", "ul", "ol":
              if node == p.children.last {
                return "\n\n"
              }
              return ""
            case "li":
              return "\n"
            default: return ""
            }
          default:
            return ""
          }
        }()
        
        let tt =  acc.hasSuffix("\n") ? trimLeft(trimmed) : trimmed
        let str = "\(acc)\(tt)\(n)"
        
        if let t = tag {
          let r = acc.endIndex ..< str.endIndex
          let nsr = nsRange(from: r, within: str)
          let tr = TaggedRange(tag: t, attributes: attributes, range: nsr)
          ranges.append(tr)
        }
        
        return str
      }
    }
    
    return (str, ranges)
  }
  
  /// Exposing the default styles for informational purposes only.
  public static let defaultStyles: [String: [String : AnyObject]] = [
    "root": [
      NSFontAttributeName: UIFont.preferredFontForTextStyle(UIFontTextStyleBody),
      NSForegroundColorAttributeName: UIColor.darkTextColor()
    ],
    "h1": [
      NSFontAttributeName: UIFont.preferredFontForTextStyle(UIFontTextStyleTitle1),
      NSForegroundColorAttributeName: UIColor.darkTextColor()
    ],
    "a": [
      NSFontAttributeName: UIFont.preferredFontForTextStyle(UIFontTextStyleBody),
      NSForegroundColorAttributeName: UIColor.blueColor()
    ]
  ]
  
  // MARK: API
  
  /// Creates and returns an attributed string from the provided tree.
  ///
  /// It should be obvious, but please note: **this can never be a proper HTML
  /// interpreter**, the attributes are set redundantly by tag name, without
  /// any optimizations—*the last one wins*.
  /// 
  /// - parameter tree: The tree to use as a source for the attributed string.
  /// - parameter styles: A dictionary of styles, dictionaries of attributes
  /// identified by tag names, to be set on the resulting attributed string. 
  /// Without styles `HTMLAttributor.defaultStyles` are used.
  /// - throws: Might throws `NSXMLParser` errors.
  /// - returns: An attributed Cocoa string.
  public func attributedString(
    tree: Node,
    styles: [String: [String : AnyObject]] = HTMLAttributor.defaultStyles
  ) throws -> NSAttributedString {
    let (str, trs) = try taggedString(tree)
    
    let astr = NSMutableAttributedString(string: str)
    
    // Global attributes must be set first.
    
    let attrs = HTMLAttributor.defaultStyles["root"]!
    astr.setAttributes(attrs, range: NSMakeRange(0, astr.length))
    
    for tr in trs {
      let tag = tr.tag
      guard var attrs = styles[tag] else {
        continue
      }
      if tag == "a" {
        if let href = tr.attributes?["href"] {
          if let url = NSURL(string: href) {
            attrs[NSLinkAttributeName] = url
          }
        }
      }
      let r = tr.range
      let l = r.location + r.length
      assert(l <= astr.length, "out of range: \(l) > \(astr.length)")
      astr.setAttributes(attrs, range: r)
    }
    
    return astr
  }
  
  /// An, admittedly rather limited, string representation of the tree, mainly
  /// used for developing and debugging this thing.
  ///
  /// - parameter tree: A tree of DOM nodes.
  /// - throws: Might throw `NSXMLParser` errors.
  /// - returns: A simplified string representation of the tree.
  public func string(tree: Node) throws -> String {
    let (str, _) = try taggedString(tree, opts: .BracketLinks)
    return str
  }
}