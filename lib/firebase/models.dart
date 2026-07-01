import 'package:cloud_firestore/cloud_firestore.dart';

class Musician {
  final String id;
  final String name;
  final String emoji;
  final String instrument;
  final String city;
  final double rating;
  final int reviews;
  final bool available;
  final bool goldRing;
  final bool online;
  final String bio;
  final String? photoURL;

  const Musician({
    required this.id,
    required this.name,
    required this.emoji,
    required this.instrument,
    required this.city,
    required this.rating,
    required this.reviews,
    required this.available,
    required this.goldRing,
    required this.online,
    required this.bio,
    this.photoURL,
  });

  factory Musician.fromFirestore(String id, Map<String, dynamic> data) {
    return Musician(
      id: id,
      name: (data['name'] ?? data['displayName'] ?? 'İstifadəçi') as String,
      emoji: (data['emoji'] ?? '🎵') as String,
      instrument: (data['instrument'] ?? data['specialty'] ?? '') as String,
      city: (data['city'] ?? '') as String,
      rating: ((data['rating'] ?? 0) as num).toDouble(),
      reviews: (data['reviews'] ?? 0) as int,
      available: (data['available'] ?? false) as bool,
      goldRing: (data['goldRing'] ?? false) as bool,
      online: (data['online'] ?? false) as bool,
      bio: (data['bio'] ?? '') as String,
      photoURL: data['photoURL'] as String?,
    );
  }
}

class Chat {
  final String id;
  final String name;
  final String emoji;
  final String lastMessage;
  final DateTime? lastMessageTime;
  final int unreadCount;
  final List<String> members;
  final bool isGroup;
  final String? photoURL;

  const Chat({
    required this.id,
    required this.name,
    required this.emoji,
    required this.lastMessage,
    this.lastMessageTime,
    required this.unreadCount,
    required this.members,
    required this.isGroup,
    this.photoURL,
  });

  factory Chat.fromFirestore(String id, Map<String, dynamic> data) {
    return Chat(
      id: id,
      name: data['name'] ?? '',
      emoji: data['emoji'] ?? '💬',
      lastMessage: data['lastMessage'] ?? '',
      lastMessageTime: data['lastMessageTime'] != null
          ? (data['lastMessageTime'] as Timestamp).toDate()
          : null,
      unreadCount: () {
        final raw = data['unreadCount'];
        if (raw == null) return 0;
        if (raw is int) return raw;
        if (raw is Map) {
          // per-user unread count map — sum all values or return 0
          try {
            return (raw.values.fold<int>(0, (acc, v) => acc + (v is int ? v : 0)));
          } catch (_) { return 0; }
        }
        return 0;
      }(),
      members: List<String>.from(data['members'] as List? ?? const []),
      isGroup: data['isGroup'] ?? false,
      photoURL: data['photoURL'],
    );
  }
}

class Event {
  final String id;
  final String day;
  final String month;
  final String title;
  final String location;
  final List<String> tags;
  final List<String> tagColors;
  final String? spots;

  const Event({
    required this.id,
    required this.day,
    required this.month,
    required this.title,
    required this.location,
    required this.tags,
    required this.tagColors,
    this.spots,
  });

  factory Event.fromFirestore(String id, Map<String, dynamic> data) {
    return Event(
      id: id,
      day: (data['day'] ?? '') as String,
      month: (data['month'] ?? '') as String,
      title: (data['title'] ?? '') as String,
      location: (data['location'] ?? '') as String,
      tags: List<String>.from(data['tags'] as List? ?? const []),
      tagColors: List<String>.from(data['tagColors'] as List? ?? const []),
      spots: data['spots'] as String?,
    );
  }
}

class Room {
  final String id;
  final String emoji;
  final String name;
  final String members;
  final String preview;
  final bool live;
  final int avatarCount;

  const Room({
    required this.id,
    required this.emoji,
    required this.name,
    required this.members,
    required this.preview,
    required this.live,
    required this.avatarCount,
  });

  factory Room.fromFirestore(String id, Map<String, dynamic> data) {
    return Room(
      id: id,
      emoji: (data['emoji'] ?? '🏛️') as String,
      name: (data['name'] ?? '') as String,
      members: (data['members'] ?? '') as String,
      preview: (data['preview'] ?? '') as String,
      live: (data['live'] ?? false) as bool,
      avatarCount: (data['avatarCount'] ?? 0) as int,
    );
  }
}

class PersonalEvent {
  final String id;
  final String ownerUid;
  final String date;
  final String type;
  final String location;
  final String notes;
  final List<String> musicians;
  final bool isAgree;
  final String? agreementChatId;
  final String? partnerUid;
  final String? partnerName;
  final String status;
  final String? cancelledBy;
  final dynamic createdAt;

  const PersonalEvent({
    required this.id,
    required this.ownerUid,
    required this.date,
    required this.type,
    required this.location,
    required this.notes,
    required this.musicians,
    required this.isAgree,
    this.agreementChatId,
    this.partnerUid,
    this.partnerName,
    this.status = 'agreed',
    this.cancelledBy,
    this.createdAt,
  });

  factory PersonalEvent.fromFirestore(String id, Map<String, dynamic> data) {
    return PersonalEvent(
      id: id,
      ownerUid: (data['ownerUid'] ?? '') as String,
      date: (data['date'] ?? '') as String,
      type: (data['type'] ?? '') as String,
      location: (data['location'] ?? '') as String,
      notes: (data['notes'] ?? '') as String,
      musicians: List<String>.from(data['musicians'] as List? ?? const []),
      isAgree: (data['isAgree'] ?? false) as bool,
      agreementChatId: data['agreementChatId'] as String?,
      partnerUid: data['partnerUid'] as String?,
      partnerName: data['partnerName'] as String?,
      status: (data['status'] ?? 'agreed') as String,
      cancelledBy: data['cancelledBy'] as String?,
      createdAt: data['createdAt'],
    );
  }
}
