import 'dart:math' as math;
import 'package:flutter/rendering.dart';
import 'package:tomeui/tomeui.dart';

/// Measures real content once, keeping the footer at the viewport bottom when
/// it fits and directly after the content when the page must scroll.
class WorkflowLayout extends MultiChildRenderObjectWidget {
  WorkflowLayout({
    required this.minimumHeight,
    required this.centerBody,
    required Widget header,
    required Widget body,
    Widget? footer,
    super.key,
  }) : super(children: [header, body, footer ?? const SizedBox.shrink()]);
  final double minimumHeight;
  final bool centerBody;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _WorkflowRender(minimumHeight, centerBody);
  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    final layout = renderObject as _WorkflowRender;
    layout.minimumHeight = minimumHeight;
    layout.centerBody = centerBody;
    renderObject.markNeedsLayout();
  }
}

class _WorkflowParentData extends ContainerBoxParentData<RenderBox> {}

class _WorkflowRender extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _WorkflowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _WorkflowParentData> {
  _WorkflowRender(this.minimumHeight, this.centerBody);
  double minimumHeight;
  bool centerBody;
  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _WorkflowParentData) {
      child.parentData = _WorkflowParentData();
    }
  }

  @override
  void performLayout() {
    final header = firstChild!;
    final body = childAfter(header)!;
    final footer = childAfter(body)!;
    for (final child in [header, body, footer]) {
      child.layout(
        BoxConstraints.tightFor(width: constraints.maxWidth),
        parentUsesSize: true,
      );
    }
    final footerGap = footer.size.height > 0 ? 20.0 : 0.0;
    final natural =
        header.size.height +
        20 +
        body.size.height +
        footerGap +
        footer.size.height;
    size = constraints.constrain(
      Size(constraints.maxWidth, math.max(minimumHeight, natural)),
    );
    final extra = math.max(0.0, size.height - natural);
    (header.parentData! as _WorkflowParentData).offset = Offset.zero;
    (body.parentData! as _WorkflowParentData).offset = Offset(
      0,
      header.size.height + 20 + (centerBody ? extra / 2 : 0),
    );
    (footer.parentData! as _WorkflowParentData).offset = Offset(
      0,
      size.height - footer.size.height,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

class WorkflowStepper extends StatelessWidget {
  const WorkflowStepper({
    required this.labels,
    required this.icons,
    required this.step,
    super.key,
  });
  final List<String> labels;
  final List<IconData> icons;
  final int step;
  @override
  Widget build(BuildContext context) {
    final palette = ThemeProvider.of(context).palette;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 280);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.max(
          constraints.maxWidth,
          labels.length *
              104.0 *
              MediaQuery.textScalerOf(context).scale(14) /
              14,
        );
        final cell = width / labels.length;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            child: Stack(
              children: [
                Positioned(
                  left: cell / 2,
                  right: cell / 2,
                  top: 19,
                  child: SizedBox(
                    height: 2,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: ColoredBox(color: palette.divider),
                        ),
                        TweenAnimationBuilder<double>(
                          tween: Tween(end: step / (labels.length - 1)),
                          duration: duration,
                          curve: Curves.easeInOut,
                          builder: (context, progress, _) =>
                              FractionallySizedBox(
                                widthFactor: progress,
                                child: ColoredBox(
                                  color: palette.primary.s500,
                                  child: const SizedBox(height: 2),
                                ),
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < labels.length; i++)
                      Expanded(
                        child: Semantics(
                          label:
                              'Step ${i + 1} of ${labels.length}: ${labels[i]}',
                          selected: i == step,
                          child: Column(
                            children: [
                              AnimatedContainer(
                                duration: duration,
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: i <= step
                                      ? palette.primary.s500
                                      : palette.surface,
                                  border: Border.all(
                                    color: i <= step
                                        ? palette.primary.s500
                                        : palette.divider,
                                    width: 2,
                                  ),
                                ),
                                child: Icon(
                                  icons[i],
                                  size: 20,
                                  color: i <= step
                                      ? palette.background
                                      : palette.text,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                ),
                                child: Text(
                                  labels[i],
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
