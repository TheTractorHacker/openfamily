import 'dart:typed_data';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../models/member.dart';
import '../services/member_avatar_cache.dart';
import '../theme/app_theme.dart';
import 'movement_icon.dart';

/// A circular avatar bubble pinned to a member's location on the map.
///
/// The bubble is a circular photo avatar (or initials fallback) with a colored
/// identity ring around it. Movement is a small circular glyph on the ring
/// (icon only — never a card covering the face). Driving speed hangs *below*
/// the pin as a caption, matching the web map. A "location error" state adds
/// a red exclamation-mark badge. Tapping the bubble opens the member's details.
class MemberAvatarBubble extends StatelessWidget {
  const MemberAvatarBubble({
    super.key,
    required this.member,
    this.onTap,
    this.radius = 22,
  });

  final Member member;
  final VoidCallback? onTap;

  /// Radius of the avatar circle in logical pixels.
  final double radius;

  /// Marker width — wide enough for a 3-digit speed caption ("128 mph").
  static const double markerWidth = 76;

  /// Height of the avatar box (circle + glyph overflow).
  static const double avatarBox = 58;

  /// Extra height hanging under the avatar for the speed caption.
  static const double speedCaptionH = 22;

  /// Gap between the avatar box and the speed caption.
  static const double speedGap = 6;

  static Size markerSizeFor(Member member) {
    return Size(
      markerWidth,
      member.hasDrivingSpeed
          ? avatarBox + speedGap + speedCaptionH
          : avatarBox,
    );
  }

  /// Alignment so the avatar center stays on the geographic point even when a
  /// speed caption hangs below.
  static Alignment markerAlignmentFor(Member member) {
    final double h = markerSizeFor(member).height;
    const double avatarCenterY = avatarBox / 2;
    return Alignment(0, (2 * avatarCenterY / h) - 1);
  }

  @override
  Widget build(BuildContext context) {
    final String tooltip = _tooltip();
    final Size size = markerSizeFor(member);

    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: tooltip,
        button: true,
        child: GestureDetector(
          onTap: onTap,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: avatarBox,
                  child: Center(
                    child: SizedBox(
                      width: radius * 2 + 14,
                      height: radius * 2 + 14,
                      child: Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.center,
                        children: [
                          StatusAvatar(
                            member: member,
                            size: radius * 2 + 6,
                          ),
                          if (member.movement != MovementType.none)
                            Positioned(
                              right: -2,
                              bottom: -2,
                              child: _MovementGlyphBadge(member: member),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (member.hasDrivingSpeed)
                  Positioned(
                    top: avatarBox + speedGap,
                    left: 0,
                    right: 0,
                    child: Center(child: _SpeedCaption(member: member)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Colorblind-safe, screen-reader-friendly description of this bubble.
  String _tooltip() {
    final StringBuffer sb = StringBuffer(member.name);
    sb.write(' — ${member.status.description}');
    if (member.movement != MovementType.none) {
      sb.write(' · ${member.isSpeeding ? 'Speeding' : member.movement.label}');
      if (member.hasDrivingSpeed) {
        sb.write(' ${member.speedMph} mph');
      }
    }
    return sb.toString();
  }
}

/// A circular photo avatar (or initials fallback) with a colored status
/// RING/OUTLINE around it — the bar's core "circular avatar bubble" +
/// "colored status circle/outline" visual.
///
/// The avatar is the member's photo (or initials on their accent color) at
/// full size; the status is a colored ring drawn *around* the photo, never a
/// fill behind it, so the ring stays visible even when a photo is present.
/// The red "location error" state additionally shows a red exclamation-mark
/// badge (not a filled disc) so the error is unmistakable.
class StatusAvatar extends StatefulWidget {
  const StatusAvatar({super.key, required this.member, this.size = 44});

  final Member member;
  final double size;

  @override
  State<StatusAvatar> createState() => _StatusAvatarState();
}

class _StatusAvatarState extends State<StatusAvatar> {
  Future<Uint8List?>? _avatarFuture;

  /// Bytes already cached when this widget was (re)configured, so the photo
  /// is part of the first frame.
  Uint8List? _initialBytes;

  /// Decoded images are cached by the framework's ImageCache under a
  /// [ResizeImage] key, so one decode serves every avatar widget of a member.
  static const int _decodeScale = 2;

  double _dpr = 1;

  @override
  void initState() {
    super.initState();
    _loadAvatar();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _dpr = MediaQuery.devicePixelRatioOf(context);
  }

  @override
  void didUpdateWidget(covariant StatusAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_avatarMetadataChanged(oldWidget.member, widget.member)) {
      _loadAvatar();
    }
  }

  void _loadAvatar() {
    _initialBytes = MemberAvatarCache.instance.peek(widget.member);
    _avatarFuture = widget.member.hasAvatar
        ? MemberAvatarCache.instance.load(widget.member)
        : null;
    // Decode as soon as the bytes land, so sibling avatar widgets of the same
    // member (marker, list row, cluster) find the decoded image in the cache.
    _avatarFuture?.then((Uint8List? bytes) {
      if (bytes == null || !mounted) return;
      precacheImage(_providerFor(bytes, _dpr), context, onError: (_, __) {});
    }, onError: (Object _) {});
  }

  /// Decodes at (about) display size instead of the file's native size: a
  /// multi-megapixel profile photo shown in a 44 dp circle used to be decoded
  /// to a 48 MB bitmap and held in the image cache.
  ImageProvider _providerFor(Uint8List bytes, double devicePixelRatio) {
    final int px = (widget.size * devicePixelRatio * _decodeScale).ceil();
    return ResizeImage(
      MemoryImage(bytes),
      width: px,
      height: px,
      policy: ResizeImagePolicy.fit,
      allowUpscaling: false,
    );
  }

  bool _avatarMetadataChanged(Member before, Member after) {
    return before.id != after.id ||
        before.hasAvatar != after.hasAvatar ||
        before.avatarVersion != after.avatarVersion;
  }

  @override
  Widget build(BuildContext context) {
    final Color statusColor = widget.member.status.color;
    final bool isError = widget.member.status == MemberStatus.error;
    final double ringWidth = _ringWidth(widget.size);

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          // The avatar itself: photo or initials, at full size.
          Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.member.avatarColor,
              boxShadow: [
                BoxShadow(
                  color: statusColor.withValues(alpha: 0.35),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ClipOval(
              child: _avatarOrInitials(),
            ),
          ),
          // Status ring drawn on top, around the avatar (never behind it).
          Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: statusColor, width: ringWidth),
            ),
          ),
          // Red exclamation-mark badge for the location-error state.
          if (isError)
            Positioned(
              top: -ringWidth,
              right: -ringWidth,
              child: _ErrorBadge(size: widget.size),
            ),
        ],
      ),
    );
  }

  /// Loads only authenticated image bytes. Until that request completes (or
  /// if it fails), preserve the familiar initials fallback.
  Widget _avatarOrInitials() {
    final Future<Uint8List?>? avatarFuture = _avatarFuture;
    if (avatarFuture == null) return _initials();

    final double dpr = _dpr;
    return FutureBuilder<Uint8List?>(
      future: avatarFuture,
      initialData: _initialBytes,
      builder: (BuildContext context, AsyncSnapshot<Uint8List?> snapshot) {
        final Uint8List? bytes = snapshot.data;
        if (bytes == null) return _initials();
        return Image(
          image: _providerFor(bytes, dpr),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _initials(),
        );
      },
    );
  }

  Widget _initials() {
    return Center(
      child: Text(
        widget.member.initials,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: widget.size * 0.4,
        ),
      ),
    );
  }

  /// Ring thickness scaled to the avatar size so it stays glanceable on the
  /// map (small) and in the profile (large).
  double _ringWidth(double s) {
    final double w = s * 0.08;
    if (w < 2.5) return 2.5;
    if (w > 4.5) return 4.5;
    return w;
  }
}

/// A small red exclamation-mark badge anchored to the top-right of an avatar,
/// used for the "location error" state. It is a red badge with a white
/// exclamation mark — not a filled disc replacing the avatar.
class _ErrorBadge extends StatelessWidget {
  const _ErrorBadge({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final double raw = size * 0.42;
    final double badgeSize = raw < 16.0 ? 16.0 : (raw > 24.0 ? 24.0 : raw);
    return Container(
      width: badgeSize,
      height: badgeSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.statusRed,
        border: Border.all(color: Colors.white, width: 1.5),
      ),
      child: Center(
        child: Text(
          '!',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            fontSize: badgeSize * 0.62,
            height: 1,
          ),
        ),
      ),
    );
  }
}

/// A cluster bubble shown when many members are near each other.
///
/// Instead of a bare "N" count, it renders an identity preview: up to three
/// stacked/overlapping member avatars plus a small count badge, so the user
/// can glance at *who* is clustered, not just how many. Each avatar keeps its
/// colored status ring (and error badge), and each moving member keeps its
/// movement glyph + speed caption below the stack — so driving / speeding
/// stay glanceable even when clustered.
class ClusterBubble extends StatelessWidget {
  const ClusterBubble({super.key, required this.members, this.onTap});

  final List<Member> members;
  final VoidCallback? onTap;

  static const double _avatarSize = 30;
  static const double _overlap = 14;

  @override
  Widget build(BuildContext context) {
    final int count = members.length;
    final List<Member> preview = members.take(3).toList();
    final double stackWidth = _avatarSize + _overlap * (preview.length - 1);
    final List<Member> moving =
        preview.where((m) => m.movement != MovementType.none).toList();
    final String label = _label();

    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        button: true,
        child: GestureDetector(
          onTap: onTap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Overlapping avatars, each with its status ring + error badge.
              SizedBox(
                width: stackWidth + 22,
                height: _avatarSize + 8,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (int i = 0; i < preview.length; i++)
                      Positioned(
                        left: i * _overlap,
                        top: 0,
                        child: StatusAvatar(
                          member: preview[i],
                          size: _avatarSize,
                        ),
                      ),
                    Positioned(
                      left: stackWidth - 4,
                      bottom: 0,
                      child: _CountBadge(count: count),
                    ),
                  ],
                ),
              ),
              // Movement glyphs (and speed captions) for each moving member.
              if (moving.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (int i = 0; i < moving.length; i++) ...[
                        if (i > 0) const SizedBox(width: 6),
                        _MovementGlyphBadge(member: moving[i]),
                        if (moving[i].hasDrivingSpeed) ...[
                          const SizedBox(width: 4),
                          _SpeedCaption(member: moving[i]),
                        ],
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Colorblind-safe, screen-reader-friendly description of the cluster.
  String _label() {
    final StringBuffer sb = StringBuffer('${members.length} people here');
    for (final Member m in members.take(3)) {
      sb.write(' · ${m.name}: ${m.status.description}');
      if (m.movement != MovementType.none) {
        sb.write(' ${m.movement.label}');
        if (m.hasDrivingSpeed) {
          sb.write(' ${m.speedMph} mph');
        }
      }
    }
    return sb.toString();
  }
}

/// A small purple count badge anchored to a cluster bubble.
class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.purple,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white, width: 1.5),
      ),
      child: Text(
        '$count',
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: 11,
        ),
      ),
    );
  }
}

/// Colors shared by the circular movement glyph and the speed caption.
/// Matches web `--status-orange-*` / `--accent-ink` / `--surface`.
const Color _badgeFill = Colors.white;
const Color _badgeInk = AppColors.accentInk;
const Color _badgeBorder = Color(0x22000000);
const Color _speedingFill = Color(0xFFFFF2DD);
const Color _speedingInk = Color(0xFF9A5800);
const Color _speedingBorder = Color(0xFFF6E0B8);

/// Small circular glyph on the avatar ring — movement icon only, so the face
/// stays fully visible. Speeding uses the warning fill rather than a wide card.
class _MovementGlyphBadge extends StatelessWidget {
  const _MovementGlyphBadge({required this.member});

  final Member member;

  @override
  Widget build(BuildContext context) {
    final bool speeding = member.isSpeeding;
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: speeding ? _speedingFill : _badgeFill,
        border: Border.all(
          color: speeding ? _speedingBorder : _badgeBorder,
        ),
        boxShadow: const [
          BoxShadow(color: Color(0x22000000), blurRadius: 3),
        ],
      ),
      child: Center(
        child: MovementIcon(
          movement: member.movement,
          size: 12,
          color: speeding ? _speedingInk : _badgeInk,
        ),
      ),
    );
  }
}

/// Numeric speed caption that hangs under the pin (or beside a cluster glyph).
/// Number is the primary read; "mph" is a smaller unit — never a card on the
/// avatar face.
class _SpeedCaption extends StatelessWidget {
  const _SpeedCaption({required this.member});

  final Member member;

  @override
  Widget build(BuildContext context) {
    final bool speeding = member.isSpeeding;
    final Color ink = speeding ? _speedingInk : _badgeInk;
    return Container(
      padding: const EdgeInsets.fromLTRB(7, 2, 7, 2),
      decoration: BoxDecoration(
        color: speeding ? _speedingFill : _badgeFill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: speeding ? _speedingBorder : _badgeBorder,
        ),
        boxShadow: const [
          BoxShadow(color: Color(0x22000000), blurRadius: 3),
        ],
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '${member.speedMph}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                height: 1.4,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: ink,
              ),
            ),
            TextSpan(
              text: ' mph',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                height: 1.4,
                color: ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
