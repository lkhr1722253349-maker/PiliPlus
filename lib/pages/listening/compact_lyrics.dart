import 'package:PiliPlus/pages/listening/controller.dart';
import 'package:PiliPlus/pages/listening/lyrics.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class CompactListeningLyrics extends StatelessWidget {
  final ListeningController controller;
  const CompactListeningLyrics({super.key, required this.controller});
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final tablet = MediaQuery.sizeOf(context).shortestSide >= 600;
      final lineHeight = constraints.maxHeight < 180
          ? constraints.maxHeight / 3
          : 60.0;
      return Align(
        alignment: tablet ? Alignment.centerRight : Alignment.center,
        child: SizedBox(
          width: tablet ? constraints.maxWidth * .60 : constraints.maxWidth,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Obx(() {
              final track = controller.activeLyrics.value;
              final position = controller.position.value;
              final offset = controller.lyricsOffset.value;
              final loading = controller.lyricsLoading.value;
              final lines = track?.displayLines ?? <LyricLine>[];
              final index = lyricIndex(lines, position, offset);
              var previous = '', current = '', next = '';
              var previousIndex = -1, nextIndex = -1;
              if (index >= 0) {
                previousIndex = index - 1;
                nextIndex = index + 1 < lines.length ? index + 1 : -1;
                previous = index > 0 ? lines[index - 1].text : '';
                current = lines[index].text;
                next = index + 1 < lines.length ? lines[index + 1].text : '';
              } else if (lines.isNotEmpty) {
                final upcoming = lines.indexWhere(
                  (e) => e.start > position - offset,
                );
                previousIndex = upcoming > 0
                    ? upcoming - 1
                    : upcoming == -1
                    ? lines.length - 1
                    : -1;
                nextIndex = upcoming;
                previous = upcoming > 0
                    ? lines[upcoming - 1].text
                    : upcoming == -1
                    ? lines.last.text
                    : '';
                current = '♪';
                next = upcoming >= 0 ? lines[upcoming].text : '';
              } else {
                current = loading
                    ? '正在查找歌词…'
                    : track?.plain.isNotEmpty == true
                    ? '此歌词没有时间轴'
                    : '暂无同步歌词';
              }
              Widget line(String text, bool focused, int lyricIndex) {
                final translated = lyricIndex >= 0 && lyricIndex < lines.length
                    ? lines[lyricIndex].translation
                    : '';
                Widget labelText(String value, bool chinese) => SizedBox(
                  height: lineHeight * (translated.isEmpty ? .9 : .45),
                  width: double.infinity,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: tablet
                        ? Alignment.centerRight
                        : Alignment.center,
                    child: Text(
                      value,
                      maxLines: 1,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: focused
                            ? FontWeight.w600
                            : FontWeight.normal,
                        fontSize: chinese
                            ? (tablet ? 19 : 15)
                            : translated.isEmpty
                            ? (tablet ? 26 : 21)
                            : (tablet ? 24 : 19),
                      ),
                    ),
                  ),
                );
                final label = SizedBox(
                  width: double.infinity,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      labelText(text, false),
                      if (translated.isNotEmpty) labelText(translated, true),
                    ],
                  ),
                );
                return SizedBox(
                  height: lineHeight,
                  child: Center(
                    child: focused
                        ? label
                        : Opacity(
                            opacity: .35,
                            child: label,
                          ),
                  ),
                );
              }

              return ClipRect(
                child: SizedBox(
                  height: lineHeight * 3,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 380),
                    switchInCurve: Curves.easeInOutCubic,
                    switchOutCurve: Curves.easeInOutCubic,
                    layoutBuilder: (currentChild, previousChildren) => Stack(
                      alignment: Alignment.center,
                      children: [...previousChildren, ?currentChild],
                    ),
                    transitionBuilder: (child, animation) => AnimatedBuilder(
                      animation: animation,
                      child: child,
                      builder: (context, child) => FractionalTranslation(
                        translation: Offset(
                          0,
                          (1 - animation.value) /
                              3 *
                              (animation.status == AnimationStatus.reverse
                                  ? -1
                                  : 1),
                        ),
                        child: Opacity(opacity: animation.value, child: child),
                      ),
                    ),
                    child: Column(
                      key: ValueKey((track, index, previous, current, next)),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        line(previous, false, previousIndex),
                        line(current, true, index),
                        line(next, false, nextIndex),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      );
    },
  );
}
