import 'dart:ui' show ImageFilter;

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
              final lines = track?.lines ?? <LyricLine>[];
              final index = lyricIndex(lines, position, offset);
              var previous = '', current = '', next = '';
              if (index >= 0) {
                previous = index > 0 ? lines[index - 1].text : '';
                current = lines[index].text;
                next = index + 1 < lines.length ? lines[index + 1].text : '';
              } else if (lines.isNotEmpty) {
                final upcoming = lines.indexWhere(
                  (e) => e.start > position - offset,
                );
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
              Widget line(String text, bool focused) {
                final label = SizedBox(
                  width: double.infinity,
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: tablet ? TextAlign.right : TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: focused ? FontWeight.w600 : FontWeight.normal,
                      fontSize: lineHeight < 40
                          ? lineHeight * .6
                          : tablet
                          ? 26
                          : 21,
                    ),
                  ),
                );
                return SizedBox(
                  height: lineHeight,
                  child: Center(
                    child: focused
                        ? label
                        : Opacity(
                            opacity: .35,
                            child: ImageFiltered(
                              imageFilter: ImageFilter.blur(
                                sigmaX: 1.2,
                                sigmaY: 1.2,
                              ),
                              child: label,
                            ),
                          ),
                  ),
                );
              }

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  line(previous, false),
                  line(current, true),
                  line(next, false),
                ],
              );
            }),
          ),
        ),
      );
    },
  );
}
