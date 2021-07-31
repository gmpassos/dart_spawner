import 'package:xml/xml.dart';

void main(List<String> args) {
  var argTitle = args[0];
  var argLang = args[1];
  var argPrice = num.parse(args[2]);

  print('XML Test - {args: $args}');

  final bookXML = '''
  <?xml version="1.0"?>
  <book>
    <title lang="$argLang">$argTitle</title>
    <price>$argPrice</price>
  </book>
  ''';

  print('XML:\n$bookXML');

  final xml = XmlDocument.parse(bookXML);

  var book = xml.getElement('book')!;
  var title = book.getElement('title')!;
  var lang = title.getAttribute('lang')!;
  var price = book.getElement('price')!;

  print('Book title: ${title.text}');
  print('Book language: $lang');
  print('Book price: ${price.text}');
}
