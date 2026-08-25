import 'package:flutter/material.dart';

/// A Card whose body can be collapsed away, leaving just the header (title +
/// optional trailing summary) visible - added 2026-08-17 so a screen with
/// several dense sections (Account Details' per-account cards, one
/// account's Balances/P&L/Fees/Open/Closed cards) can be tidied down to just
/// headers instead of always showing everything at once.
///
/// Defaults to expanded (initiallyExpanded: true) so adding this to an
/// existing screen changes nothing visually until the user actually taps a
/// header - purely additive, not a new default layout.
class CollapsibleCard extends StatefulWidget {
  final Widget title;
  final Widget? trailing;
  final List<Widget> children;
  final bool initiallyExpanded;
  final EdgeInsetsGeometry padding;

  const CollapsibleCard({
    super.key,
    required this.title,
    this.trailing,
    required this.children,
    this.initiallyExpanded = true,
    this.padding = const EdgeInsets.all(14),
  });

  @override
  State<CollapsibleCard> createState() => _CollapsibleCardState();
}

class _CollapsibleCardState extends State<CollapsibleCard> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: widget.padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                children: [
                  Expanded(child: widget.title),
                  if (widget.trailing != null) ...[
                    widget.trailing!,
                    const SizedBox(width: 4),
                  ],
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(Icons.expand_more, color: Colors.grey[500]),
                  ),
                ],
              ),
            ),
            AnimatedCrossFade(
              firstChild: const SizedBox(width: double.infinity, height: 0),
              secondChild: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: widget.children,
              ),
              crossFadeState: _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 200),
              sizeCurve: Curves.easeInOut,
            ),
          ],
        ),
      ),
    );
  }
}
