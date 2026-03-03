import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class _EmojiCategory {
  final IconData icon;
  final List<String> emojis;
  const _EmojiCategory(this.icon, this.emojis);
}

/// Apple-style emoji picker that matches StrokeKeyboard height exactly.
/// Has an ABC button at bottom-left to switch back to the letter keyboard.
class EmojiPicker extends StatefulWidget {
  final void Function(String emoji) onEmojiSelected;
  final VoidCallback? onBackspace;
  final VoidCallback? onSwitchToKeyboard;
  final double height;

  const EmojiPicker({
    super.key,
    required this.onEmojiSelected,
    this.onBackspace,
    this.onSwitchToKeyboard,
    this.height = 300,
  });

  @override
  State<EmojiPicker> createState() => _EmojiPickerState();
}

class _EmojiPickerState extends State<EmojiPicker> {
  late final PageController _pageCtrl;
  int _currentPage = 0;

  static const _cols = 8;
  static const _rows = 5;
  static const _perPage = _cols * _rows;

  static final _categories = [
    _EmojiCategory(Icons.emoji_emotions_outlined, _smileys),
    _EmojiCategory(Icons.back_hand_outlined, _people),
    _EmojiCategory(Icons.pets_outlined, _animals),
    _EmojiCategory(Icons.fastfood_outlined, _food),
    _EmojiCategory(Icons.sports_soccer_outlined, _activities),
    _EmojiCategory(Icons.directions_car_outlined, _travel),
    _EmojiCategory(Icons.lightbulb_outline, _objects),
    _EmojiCategory(Icons.favorite_outline, _symbols),
    _EmojiCategory(Icons.flag_outlined, _flags),
  ];

  static late final List<List<String>> _pages;
  static late final List<int> _pageCategory;
  static late final List<int> _categoryStartPage;
  static bool _built = false;

  static void _buildPages() {
    if (_built) return;
    _pages = [];
    _pageCategory = [];
    _categoryStartPage = [];
    for (var c = 0; c < _categories.length; c++) {
      _categoryStartPage.add(_pages.length);
      final emojis = _categories[c].emojis;
      for (var i = 0; i < emojis.length; i += _perPage) {
        final end = (i + _perPage).clamp(0, emojis.length);
        _pages.add(emojis.sublist(i, end));
        _pageCategory.add(c);
      }
    }
    _built = true;
  }

  @override
  void initState() {
    super.initState();
    _buildPages();
    _pageCtrl = PageController();
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  int get _activeCategoryIndex =>
      _currentPage < _pageCategory.length ? _pageCategory[_currentPage] : 0;

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    // StrokeKeyboard: 8 top + 220 content + (bottomPad + 30) = 258 + bottomPad
    // Emoji picker: 8 top + grid + 34 bottom bar + (bottomPad + 30)
    // grid = 220 - 34 = 186
    const topPad = 8.0;
    const barH = 34.0;
    const gridHeight = 220.0 - barH; // 186
    final cellH = gridHeight / _rows;
    final totalHeight = topPad + 220.0 + bottomPad + 30;

    return Container(
      height: totalHeight,
      color: const Color(0xFF1C1C1E),
      child: Column(
        children: [
          SizedBox(height: topPad),
          // ── Swipeable emoji grid ──
          SizedBox(
            height: gridHeight,
            child: PageView.builder(
              controller: _pageCtrl,
              itemCount: _pages.length,
              onPageChanged: (i) => setState(() => _currentPage = i),
              itemBuilder: (_, pageIdx) {
                final emojis = _pages[pageIdx];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Wrap(
                    children: List.generate(_perPage, (j) {
                      final w = (MediaQuery.of(context).size.width - 8) / _cols;
                      if (j >= emojis.length) {
                        return SizedBox(width: w, height: cellH);
                      }
                      return GestureDetector(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          widget.onEmojiSelected(emojis[j]);
                        },
                        behavior: HitTestBehavior.opaque,
                        child: SizedBox(
                          width: w,
                          height: cellH,
                          child: Center(
                            child: Text(
                              emojis[j],
                              style: const TextStyle(fontSize: 26),
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                );
              },
            ),
          ),

          // ── Bottom bar: ABC (plain text) | category icons | backspace ──
          SizedBox(
            height: barH,
            child: Row(
              children: [
                // ABC — plain text, no container
                if (widget.onSwitchToKeyboard != null)
                  GestureDetector(
                    onTap: widget.onSwitchToKeyboard,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 40,
                      alignment: Alignment.center,
                      child: Text(
                        'ABC',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w400,
                          color: Colors.white.withValues(alpha: 0.5),
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                  ),
                // Category icons
                ...List.generate(_categories.length, (i) {
                  final active = i == _activeCategoryIndex;
                  return Expanded(
                    child: GestureDetector(
                      onTap: () {
                        final target = _categoryStartPage[i];
                        _pageCtrl.animateToPage(
                          target,
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeInOut,
                        );
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: active
                              ? const Color(0xFF3A3A3C)
                              : Colors.transparent,
                          shape: BoxShape.circle,
                        ),
                        margin: const EdgeInsets.symmetric(
                          horizontal: 2, vertical: 4,
                        ),
                        child: Icon(
                          _categories[i].icon,
                          size: 20,
                          color: active
                              ? Colors.white
                              : Colors.white.withValues(alpha: 0.4),
                        ),
                      ),
                    ),
                  );
                }),
                // Backspace
                if (widget.onBackspace != null)
                  GestureDetector(
                    onTap: widget.onBackspace,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 40,
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.backspace_outlined,
                        size: 20,
                        color: Colors.white.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Safe area spacer
          SizedBox(height: bottomPad + 30),
        ],
      ),
    );
  }
}

// ── Emoji data ──

const _smileys = [
  '😀','😃','😄','😁','😆','😅','🤣','😂','🙂','🙃',
  '😉','😊','😇','🥰','😍','🤩','😘','😗','😚','😙',
  '🥲','😋','😛','😜','🤪','😝','🤑','🤗','🤭','🤫',
  '🤔','🫡','🤐','🤨','😐','😑','😶','🫥','😏','😒',
  '🙄','😬','🤥','😌','😔','😪','🤤','😴','😷','🤒',
  '🤕','🤢','🤮','🥵','🥶','🥴','😵','🤯','🤠','🥳',
  '🥸','😎','🤓','🧐','😕','🫤','😟','🙁','😮','😯',
  '😲','😳','🥺','🥹','😦','😧','😨','😰','😥','😢',
  '😭','😱','😖','😣','😞','😓','😩','😫','🥱','😤',
  '😡','😠','🤬','😈','👿','💀','☠️','💩','🤡','👹',
  '👺','👻','👽','👾','🤖','😺','😸','😹','😻','😼',
  '😽','🙀','😿','😾',
];

const _people = [
  '👋','🤚','🖐️','✋','🖖','🫱','🫲','🫳','🫴','👌',
  '🤌','🤏','✌️','🤞','🫰','🤟','🤘','🤙','👈','👉',
  '👆','🖕','👇','☝️','🫵','👍','👎','✊','👊','🤛',
  '🤜','👏','🙌','🫶','👐','🤲','🤝','🙏','✍️','💅',
  '🤳','💪','🦾','🦿','🦵','🦶','👂','🦻','👃','🧠',
  '🫀','🫁','🦷','🦴','👀','👁️','👅','👄','🫦','👶',
  '🧒','👦','👧','🧑','👱','👨','🧔','👩','🧓','👴',
  '👵','🙍','🙎','🙅','🙆','💁','🙋','🧏','🙇','🤦',
  '🤷','👮','🕵️','💂','🥷','👷','🫅','🤴','👸','👳',
  '👲','🧕','🤵','👰','🤰','🫃','🫄','🤱','👼','🎅',
  '🤶','🦸','🦹','🧙','🧚','🧛','🧜','🧝','🧞','🧟',
];

const _animals = [
  '🐶','🐱','🐭','🐹','🐰','🦊','🐻','🐼','🐻‍❄️','🐨',
  '🐯','🦁','🐮','🐷','🐸','🐵','🙈','🙉','🙊','🐒',
  '🐔','🐧','🐦','🐤','🐣','🐥','🦆','🦅','🦉','🦇',
  '🐺','🐗','🐴','🦄','🐝','🪱','🐛','🦋','🐌','🐞',
  '🐜','🪰','🪲','🪳','🦟','🦗','🕷️','🦂','🐢','🐍',
  '🦎','🦖','🦕','🐙','🦑','🦐','🦞','🦀','🪸','🐡',
  '🐠','🐟','🐬','🐳','🐋','🦈','🪼','🐊','🐅','🐆',
  '🦓','🫏','🦍','🦧','🐘','🦛','🦏','🐪','🐫','🦒',
  '🦘','🦬','🐃','🐂','🐄','🐎','🐖','🐏','🐑','🦙',
  '🐐','🦌','🐕','🐩','🦮','🐕‍🦺','🐈','🐈‍⬛','🪶','🐓',
  '🦃','🦤','🦚','🦜','🦢','🪿','🦩','🕊️','🐇','🦝',
  '🦨','🦡','🦫','🦦','🦥','🐁','🐀','🐿️','🦔',
];

const _food = [
  '🍎','🍐','🍊','🍋','🍌','🍉','🍇','🍓','🫐','🍈',
  '🍒','🍑','🥭','🍍','🥥','🥝','🍅','🍆','🥑','🫛',
  '🥦','🥬','🥒','🌶️','🫑','🌽','🥕','🫒','🧄','🧅',
  '🥔','🍠','🫘','🥐','🥖','🍞','🥨','🧀','🥚','🍳',
  '🧈','🥞','🧇','🥓','🥩','🍗','🍖','🦴','🌭','🍔',
  '🍟','🍕','🫓','🥪','🥙','🧆','🌮','🌯','🫔','🥗',
  '🥘','🫕','🥫','🍝','🍜','🍲','🍛','🍣','🍱','🥟',
  '🦪','🍤','🍙','🍚','🍘','🍥','🥠','🥮','🍢','🍡',
  '🍧','🍨','🍦','🥧','🧁','🍰','🎂','🍮','🍭','🍬',
  '🍫','🍿','🍩','🍪','🌰','🥜','🍯','🥛','🍼','🫖',
  '☕','🍵','🧃','🥤','🧋','🫙','🍶','🍺','🍻','🥂',
  '🍷','🥃','🍸','🍹','🧉','🍾','🧊','🥄','🍴','🍽️',
];

const _activities = [
  '⚽','🏀','🏈','⚾','🥎','🎾','🏐','🏉','🥏','🎱',
  '🪀','🏓','🏸','🏒','🏑','🥍','🏏','🪃','🥅','⛳',
  '🪁','🏹','🎣','🤿','🥊','🥋','🎽','🛹','🛼','🛷',
  '⛸️','🥌','🎿','⛷️','🏂','🪂','🏋️','🤼','🤸','⛹️',
  '🤺','🤾','🏌️','🏇','🧘','🏄','🏊','🤽','🚣','🧗',
  '🚵','🚴','🏆','🥇','🥈','🥉','🏅','🎖️','🏵️','🎗️',
  '🎪','🤹','🎭','🩰','🎨','🎬','🎤','🎧','🎼','🎹',
  '🥁','🪘','🎷','🎺','🪗','🎸','🪕','🎻','🎲','♟️',
  '🎯','🎳','🎮','🕹️','🎰',
];

const _travel = [
  '🚗','🚕','🚙','🚌','🚎','🏎️','🚓','🚑','🚒','🚐',
  '🛻','🚚','🚛','🚜','🏍️','🛵','🛺','🚲','🛴','🚏',
  '🛣️','🛤️','⛽','🛞','🚨','🚥','🚦','🛑','🚧','⚓',
  '🛟','⛵','🚤','🛳️','⛴️','🛥️','🚢','✈️','🛩️','🛫',
  '🛬','🪂','💺','🚁','🚟','🚠','🚡','🛰️','🚀','🛸',
  '🌍','🌎','🌏','🗺️','🧭','🏔️','⛰️','🌋','🗻','🏕️',
  '🏖️','🏜️','🏝️','🏞️','🏟️','🏛️','🏗️','🧱','🪨','🪵',
  '🛖','🏘️','🏚️','🏠','🏡','🏢','🏣','🏤','🏥','🏦',
  '🏨','🏩','🏪','🏫','🏬','🏭','🏯','🏰','💒','🗼',
  '🗽','⛪','🕌','🛕','🕍','⛩️','🕋','⛲','⛺','🌁',
  '🌃','🏙️','🌄','🌅','🌆','🌇','🌉','🗾','🎑','🎆',
  '🎇','🧨','🎏','🎐','🎋','🎍',
];

const _objects = [
  '💡','🔦','🕯️','📱','💻','⌨️','🖥️','🖨️','🖱️','🖲️',
  '💾','💿','📀','📷','📸','📹','🎥','📽️','🎞️','📞',
  '☎️','📟','📠','📺','📻','🎙️','🎚️','🎛️','🧭','⏱️',
  '⏲️','⏰','🕰️','⌛','⏳','📡','🔋','🪫','🔌','💰',
  '🪙','💴','💵','💶','💷','💸','💳','🧾','💎','⚖️',
  '🪜','🧰','🪛','🔧','🔨','⚒️','🛠️','⛏️','🪚','🔩',
  '⚙️','🪤','🧲','🔫','💣','🧨','🪓','🔪','🗡️','⚔️',
  '🛡️','🚬','⚰️','🪦','⚱️','🏺','🔮','📿','🧿','🪬',
  '💈','⚗️','🔭','🔬','🕳️','🩹','🩺','🩻','🩼','💊',
  '💉','🩸','🧬','🦠','🧫','🧪','🌡️','🧹','🪠','🧺',
  '🧻','🚽','🪣','🧼','🫧','🪥','🧽','🧯','🛒','🚬',
  '🪑','🚪','🪞','🪟','🛏️','🛋️','🪑','🚿','🛁','🪤',
];

const _symbols = [
  '❤️','🧡','💛','💚','💙','💜','🖤','🤍','🤎','💔',
  '❤️‍🔥','❤️‍🩹','❣️','💕','💞','💓','💗','💖','💘','💝',
  '💟','☮️','✝️','☪️','🕉️','☸️','✡️','🔯','🕎','☯️',
  '☦️','🛐','⛎','♈','♉','♊','♋','♌','♍','♎',
  '♏','♐','♑','♒','♓','🆔','⚛️','🉑','☢️','☣️',
  '📴','📳','🈶','🈚','🈸','🈺','🈷️','✴️','🆚','💮',
  '🉐','㊙️','㊗️','🈴','🈵','🈹','🈲','🅰️','🅱️','🆎',
  '🆑','🅾️','🆘','❌','⭕','🛑','⛔','📛','🚫','💯',
  '💢','♨️','🚷','🚯','🚳','🚱','🔞','📵','🚭','❗',
  '❕','❓','❔','‼️','⁉️','🔅','🔆','〽️','⚠️','🚸',
  '🔱','⚜️','🔰','♻️','✅','🈯','💹','❇️','✳️','❎',
  '🌐','💠','Ⓜ️','🌀','💤','🏧','🚾','♿','🅿️','🛗',
  '🈳','🈂️','🛂','🛃','🛄','🛅','🚹','🚺','🚼','⚧️',
  '🚻','🚮','🎦','📶','🈁','🔣','ℹ️','🔤','🔡','🔠',
  '🆖','🆗','🆙','🆒','🆕','🆓','0️⃣','1️⃣','2️⃣','3️⃣',
  '4️⃣','5️⃣','6️⃣','7️⃣','8️⃣','9️⃣','🔟','🔢','#️⃣','*️⃣',
  '⏏️','▶️','⏸️','⏯️','⏹️','⏺️','⏭️','⏮️','⏩','⏪',
  '⬆️','↗️','➡️','↘️','⬇️','↙️','⬅️','↖️','↕️','↔️',
  '↩️','↪️','⤴️','⤵️','🔀','🔁','🔂','🔄','🔃','🎵',
  '🎶','✖️','➕','➖','➗','♾️','💲','💱','™️','©️',
  '®️','〰️','➰','➿','🔚','🔙','🔛','🔝','🔜','✔️',
  '☑️','🔘','🔴','🟠','🟡','🟢','🔵','🟣','⚫','⚪',
  '🟤','🔺','🔻','🔸','🔹','🔶','🔷','🔳','🔲','▪️',
  '▫️','◾','◽','◼️','◻️','🟥','🟧','🟨','🟩','🟦',
  '🟪','⬛','⬜','🟫','🔈','🔇','🔉','🔊','🔔','🔕',
  '📣','📢','💬','💭','🗯️','♠️','♣️','♥️','♦️','🃏',
  '🎴','🀄','🕐','🕑','🕒','🕓','🕔','🕕','🕖','🕗',
  '🕘','🕙','🕚','🕛',
];

const _flags = [
  '🏳️','🏴','🏁','🚩','🏳️‍🌈','🏳️‍⚧️','🏴‍☠️',
  '🇺🇸','🇬🇧','🇫🇷','🇩🇪','🇮🇹','🇪🇸','🇵🇹','🇧🇷','🇲🇽','🇦🇷',
  '🇨🇦','🇦🇺','🇯🇵','🇰🇷','🇨🇳','🇮🇳','🇷🇺','🇹🇷','🇸🇦','🇦🇪',
  '🇪🇬','🇿🇦','🇳🇬','🇰🇪','🇬🇭','🇲🇦','🇹🇳','🇮🇱','🇵🇰','🇧🇩',
  '🇮🇩','🇹🇭','🇻🇳','🇵🇭','🇲🇾','🇸🇬','🇳🇿','🇫🇮','🇸🇪','🇳🇴',
  '🇩🇰','🇮🇸','🇮🇪','🇳🇱','🇧🇪','🇨🇭','🇦🇹','🇵🇱','🇨🇿','🇷🇴',
  '🇭🇺','🇬🇷','🇺🇦','🇭🇷','🇷🇸','🇧🇬','🇸🇰','🇸🇮','🇱🇹','🇱🇻',
  '🇪🇪','🇨🇴','🇨🇱','🇵🇪','🇻🇪','🇪🇨','🇺🇾','🇵🇾','🇧🇴','🇨🇷',
  '🇵🇦','🇨🇺','🇩🇴','🇭🇳','🇬🇹','🇸🇻','🇳🇮','🇯🇲','🇭🇹','🇹🇹',
  '🇧🇸','🇧🇧','🇱🇨','🇰🇳','🇦🇬','🇩🇲','🇬🇩','🇻🇨','🇬🇾','🇸🇷',
];
