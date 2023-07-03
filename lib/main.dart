import 'dart:async';

import 'package:cbl/cbl.dart';
import 'package:cbl_flutter/cbl_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await CouchbaseLiteFlutter.init();
  await openDatabase();
  await startReplication();
  runApp(const ChatApp());
}

class ChatApp extends StatelessWidget {
  const ChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: ChatPage(),
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  var _messages = <Message>[];
  List<Message>? _foundMessages;
  late final StreamSubscription _messagesSubscription;
  final _messageInputController = TextEditingController();
  final _messageInputFocusNode = FocusNode();
  Message? _editMessage;

  bool get _isEditing => _editMessage != null;
  bool get _isSearching => _foundMessages != null;

  @override
  void initState() {
    super.initState();
    _messagesSubscription = watchMessages()
        .listen((messages) => setState(() => _messages = messages));
  }

  @override
  void dispose() {
    _messagesSubscription.cancel();
    _messageInputController.dispose();
    _messageInputFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildSearchInput(),
            Expanded(child: _buildMessageList()),
            _buildMessageInput(),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageList() {
    return ListView.builder(
      reverse: !_isSearching,
      padding: const EdgeInsets.all(8),
      itemBuilder: (context, index) {
        final messages = _foundMessages ?? _messages;
        if (messages.length <= index) {
          return null;
        }

        final message = messages[index];

        return Padding(
          padding: const EdgeInsets.all(8),
          child: MessageTile(
            message: message,
            isFromCurrentUser: !_isSearching && message.author == currentAuthor,
            onEdit: () {
              setState(() => _editMessage = message);
              _messageInputController.text = message.text;
              _messageInputFocusNode.requestFocus();
            },
          ),
        );
      },
    );
  }

  Widget _buildMessageInput() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: TextFormField(
        controller: _messageInputController,
        focusNode: _messageInputFocusNode,
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          labelText: 'Message',
        ),
        onFieldSubmitted: (text) {
          final now = DateTime.now();
          if (text.isNotEmpty) {
            if (!_isEditing) {
              saveMessage(Message(
                text: text,
                author: currentAuthor,
                sentAt: now,
                updatedAt: now,
              ));
            } else {
              saveMessage(_editMessage!.copyWith(text: text, updatedAt: now));
              setState(() => _editMessage = null);
            }
            _messageInputController.clear();
          }
        },
      ),
    );
  }

  Widget _buildSearchInput() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: TextFormField(
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          labelText: 'Search',
        ),
        onChanged: (text) {
          if (text.isNotEmpty) {
            searchMessages(text)
                .then((messages) => setState(() => _foundMessages = messages));
          } else {
            setState(() => _foundMessages = null);
          }
        },
      ),
    );
  }
}

late final Database database;

Future<void> openDatabase() async {
  database = await Database.openAsync('messages');
  await database.createIndex('text_fts', FullTextIndexConfiguration(['text']));
}

Future<void> startReplication() async {
  final replicator = await Replicator.create(ReplicatorConfiguration(
    database: database,
    target: UrlEndpoint(Uri.parse('ws://localhost:4984/messages')),
    continuous: true,
    conflictResolver: ConflictResolver.from((conflict) {
      final localDocument = conflict.localDocument;
      final remoteDocument = conflict.remoteDocument;

      if (localDocument == null) {
        return remoteDocument;
      }

      if (remoteDocument == null) {
        return localDocument;
      }

      final localMessage = localDocument.toEntity(Message.fromJson);
      final remoteMessage = remoteDocument.toEntity(Message.fromJson);

      return localMessage.updatedAt.isAfter(remoteMessage.updatedAt)
          ? localDocument
          : remoteDocument;
    }),
  ));
  await replicator.start();
}

Stream<List<Message>> watchMessages() async* {
  final query = await Query.fromN1ql(database, '''
    SELECT META().id, text, author, sentAt, updatedAt
    FROM _
    ORDER BY sentAt DESC
  ''');
  yield* query.changes().asyncMap(
        (change) => change.results
            .asStream()
            .map((result) => result.toEntity(Message.fromJson))
            .toList(),
      );
}

Future<void> saveMessage(Message message) async {
  final document = message.id == null
      ? MutableDocument()
      : (await database.document(message.id!))!.toMutable();
  document.updateFromEntity(message);
  await database.saveDocument(document, ConcurrencyControl.failOnConflict);
}

Future<List<Message>> searchMessages(String prompt) async {
  final words = prompt.trim().split(RegExp(r'\s+'));
  final ftsQuery = '${words.join(' AND ')}*';
  final query = await Query.fromN1ql(database, r'''
    SELECT META().id, text, author, sentAt, updatedAt
    FROM _
    WHERE MATCH(text_fts, $ftsQuery)
    ORDER BY RANK(text_fts)
  ''');
  await query.setParameters(Parameters({'ftsQuery': ftsQuery}));
  final results = await query.execute();
  return results
      .asStream()
      .map((result) => result.toEntity(Message.fromJson))
      .toList();
}

final currentAuthor = defaultTargetPlatform.name;

class Message {
  Message({
    this.id,
    required this.text,
    required this.author,
    required this.sentAt,
    required this.updatedAt,
  });

  factory Message.fromJson(Map<String, Object?> json) {
    return Message(
      id: json['id'] as String?,
      text: json['text'] as String,
      author: json['author'] as String,
      sentAt: DateTime.parse(json['sentAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }

  final String? id;
  final String text;
  final String author;
  final DateTime sentAt;
  final DateTime updatedAt;

  Message copyWith({
    String? id,
    String? text,
    String? author,
    DateTime? sentAt,
    DateTime? updatedAt,
  }) =>
      Message(
        id: id ?? this.id,
        text: text ?? this.text,
        author: author ?? this.author,
        sentAt: sentAt ?? this.sentAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'text': text,
        'author': author,
        'sentAt': sentAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };
}

extension on DictionaryInterface {
  T toEntity<T>(T Function(Map<String, Object?> json) fromJson) {
    final json = toPlainMap();
    if (this case Document(:final id)) {
      json['id'] = id;
    }
    return fromJson(json);
  }
}

extension on MutableDictionaryInterface {
  void updateFromEntity(Object entity) {
    final json = (entity as dynamic).toJson() as Map<String, Object?>;
    if (this is MutableDocument) {
      json.remove('id');
    }
    setData(json);
  }
}

class MessageTile extends StatelessWidget {
  const MessageTile({
    super.key,
    required this.message,
    required this.isFromCurrentUser,
    required this.onEdit,
  });

  final Message message;
  final bool isFromCurrentUser;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment:
          isFromCurrentUser ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () {
          if (isFromCurrentUser) {
            onEdit();
          }
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
            child: Column(
              crossAxisAlignment: isFromCurrentUser
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                Text(
                  isFromCurrentUser ? 'Me' : message.author,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(width: 8),
                Text(
                  message.text,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
