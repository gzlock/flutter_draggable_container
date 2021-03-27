import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Widget;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'draggable_item_recognizer.dart';
import 'about_rect.dart';
import 'delete_button.dart';
import 'draggable_item.dart';
import 'draggable_item_widget.dart';
import 'draggable_slot.dart';
import 'utils.dart';

typedef Widget? NullableItemBuilder<T extends DraggableItem>(
  BuildContext context,
  T? item,
  int index,
);

class DraggableContainer<T extends DraggableItem> extends StatefulWidget {
  final List<T?> items;
  final NullableItemBuilder<T> itemBuilder;
  final NullableItemBuilder<T>? deleteButtonBuilder;
  final NullableItemBuilder<T>? slotBuilder;
  final SliverGridDelegate gridDelegate;
  final EdgeInsets? padding;
  final Duration animationDuration;
  final void Function(List<T?> items)? onChange;
  final void Function(bool editting)? onEditModeChange;
  final bool? tapOutSizeExitEdieMode;
  final BoxDecoration? draggingDecoration;

  const DraggableContainer({
    Key? key,
    required this.items,
    required this.itemBuilder,
    required this.gridDelegate,
    this.deleteButtonBuilder,
    this.slotBuilder,
    this.padding,
    this.onChange,
    this.onEditModeChange,
    this.tapOutSizeExitEdieMode,
    this.draggingDecoration,
    Duration? animationDuration,
  })  : animationDuration =
            animationDuration ?? const Duration(milliseconds: 200),
        super(key: key);

  @override
  DraggableContainerState<T> createState() => DraggableContainerState<T>();
}

class DraggableContainerState<T extends DraggableItem>
    extends State<DraggableContainer<T>>
    with SingleTickerProviderStateMixin, AboutRect {
  late final List<T?> items = widget.items.toList();
  final Map<GlobalKey<DraggableSlotState<T>>,
      GlobalKey<DraggableWidgetState<T>>?> _relationship = {};
  final List<DraggableSlot<T>> _slots = [];
  final List<DraggableWidget<T>> _children = [];
  double layoutWidth = 0;
  double _maxHeight = 0;

  late final GestureRecognizerFactory _longPressRecognizer =
      GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
          () => LongPressGestureRecognizer(),
          (LongPressGestureRecognizer instance) {
    instance
      ..onLongPressStart = onLongPressStart
      ..onLongPressMoveUpdate = onLongPressMoveUpdate
      ..onLongPressEnd = onLongPressEnd;
  });

  late final GestureRecognizerFactory _draggableItemRecognizer =
      GestureRecognizerFactoryWithHandlers<DraggableItemRecognizer>(
          () => DraggableItemRecognizer(containerState: this),
          (DraggableItemRecognizer instance) {
    instance
      ..isHitItem = _isHitItem
      ..isDraggingItem = () {
        return pickUp != null;
      }
      ..onPanStart = onPanStart
      ..onPanUpdate = onPanUpdate
      ..onPanEnd = onPanEnd;
  });

  /// 事件竞技场
  late final Map<Type, GestureRecognizerFactory> _gestures = {
    LongPressGestureRecognizer: _longPressRecognizer,
  };

  DraggableWidgetState<T>? pickUp;

  GlobalKey<DraggableSlotState<T>>? _fromSlot;

  Widget? draggingWidget;
  T? draggingItem;
  GlobalKey<DraggableWidgetState>? draggingKey;

  Size get itemSize => super.itemSize;
  late bool _tapOutSizeExitEditMode = widget.tapOutSizeExitEdieMode ?? true;

  bool get tapOutSideExitEditMode => this._tapOutSizeExitEditMode;

  Map<GlobalKey<DraggableSlotState<T>>, GlobalKey<DraggableWidgetState<T>>?>
      get relationship => _relationship;

  set tapOutSideExitEditMode(bool value) =>
      this._tapOutSizeExitEditMode = value;

  bool _editMode = false;

  bool get editMode => _editMode;

  List<GlobalKey<DraggableSlotState<T>>> get slots =>
      _relationship.keys.toList();

  set editMode(bool value) {
    _editMode = value;
    if (value) {
      // 进入编辑模式
      _createOverlay();
      // _gestures.remove(LongPressGestureRecognizer);
      _gestures[DraggableItemRecognizer] = _draggableItemRecognizer;
    } else {
      // 退出编辑模式
      _removeOverlay();
      _gestures.remove(DraggableItemRecognizer);
      // _gestures[LongPressGestureRecognizer] = _longPressRecognizer;
    }
    _relationship.forEach((slot, item) {
      if (item == null) return;
      item.currentState?.edit = _editMode;
    });
    setState(() {});
    widget.onEditModeChange?.call(_editMode);
  }

  OverlayEntry? _overlayEntry;
  late GlobalKey _stackKey = GlobalKey();

  void _createOverlay() {
    print('_createOverlay');
    _overlayEntry?.remove();
    if (!_tapOutSizeExitEditMode) return;
    final rect = getRect(context);

    _overlayEntry = new OverlayEntry(
      builder: (context) {
        return Stack(
          children: [
            Listener(
              behavior: HitTestBehavior.translucent,
              onPointerUp: (e) {
                if (!rect.contains(e.position) && pickUp == null) {
                  editMode = false;
                }
              },
            ),
            // Positioned.fromRect(
            //   rect: rect,
            //   child: Container(
            //     color: Colors.yellow.withOpacity(0.3),
            //   ),
            // ),
            if (pickUp != null) pickUp!.widget,
          ],
        );
      },
    );
    Overlay.of(context)!.insert(_overlayEntry!);
  }

  void _removeOverlay() {
    print('_removeOverlay');
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  bool _created = false;

  void _createSlots() {
    if (_created) return;
    _created = true;
    _slots.clear();
    _children.clear();
    _relationship.clear();
    List.generate(items.length, (index) {
      // didUpdateWidget 创建DraggableWidget
      final rect = calcSlotRect(index: index, layoutWidth: layoutWidth);
      // addSlot(widget.items[index], update: false);
      final slot = _createSlot(index: index, item: items[index], rect: rect);
      _relationship[slot.key] = null;
      _slots.add(slot);
    });
  }

  void _updateSlots() {
    final entries = _relationship.entries;
    late Rect rect;
    for (var index = 0; index < entries.length; index++) {
      final entry = entries.elementAt(index);
      final key = entry.key;
      final value = entry.value;
      rect = calcSlotRect(index: index, layoutWidth: layoutWidth);
      // print('更新槽 $index ${key.currentState}');
      key.currentState?.rect = rect;
      value?.currentState?.rect = rect;
    }
    _maxHeight = rect.bottom;
    SchedulerBinding.instance?.addPostFrameCallback((timeStamp) {
      _buildSlotRectCaches();
    });
  }

  DraggableWidget<T>? _createItem({
    required int index,
    T? item,
    required Rect rect,
  }) {
    Widget? child = widget.itemBuilder(context, item, index);
    if (child == null) return null;
    Widget button = widget.deleteButtonBuilder?.call(context, item, index) ??
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: Colors.red,
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
          child: Icon(
            Icons.clear,
            size: 14,
            color: Colors.white,
          ),
        );
    return DraggableWidget(
      key: GlobalKey<DraggableWidgetState<T>>(),
      rect: rect,
      item: item,
      duration: widget.animationDuration,
      child: child,
      draggingDecoration: widget.draggingDecoration,
      deleteButton: GestureDetector(
        child: DeleteItemButton(child: button),
        onTap: () {
          removeItem(item!);
        },
      ),
    );
  }

  @override
  void didUpdateWidget(DraggableContainer<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    print('didUpdateWidget $pickUp');
    if (pickUp != null) return;
    _children.clear();
    final keys = _relationship.keys.toList();
    keys.forEach((key) {
      final index = keys.indexOf(key);
      final rect = calcSlotRect(index: index, layoutWidth: layoutWidth);
      final child = _createItem(index: index, rect: rect, item: items[index]);
      _relationship[key] = child?.key;
      if (child != null) _children.add(child);
    });
  }

  bool _isHitItem(Offset globalPosition) {
    return findItemByEventPosition(globalPosition) != null;
  }

  DraggableWidgetState<T>? findItemByEventPosition(Offset globalPosition) {
    final HitTestResult result = HitTestResult();
    WidgetsBinding.instance!.hitTest(result, globalPosition);
    // print('path length ${result.path.length}');
    for (HitTestEntry entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData) {
        final data = target.metaData;
        if (data is DraggableWidgetState<T> && data != pickUp) {
          return data;
        } else if (data is DeleteItemButton) {
          return null;
        }
      }
    }
  }

  void _buildSlotRectCaches() {
    buildSlotRectCaches(_relationship.keys.map((e) => e.currentContext!));
  }

  Offset _dragOffset = Offset.zero;

  onPanStart(DragStartDetails _) {
    _buildSlotRectCaches();
    var _pickUp = findItemByEventPosition(_.globalPosition);
    if (_pickUp != null && _pickUp.item?.fixed == false) {
      this.pickUp = _pickUp;
      _dragOffset = getRect(_stackKey.currentContext!).topLeft;
      _fromSlot = findSlotFromItemState(_pickUp);
      _children.remove(_pickUp.widget);
      print('panStart children.length ${_children.length}');
      _pickUp.dragging = true;
      final offset = pickUp!.rect.topLeft + _dragOffset;
      _pickUp.rect = Rect.fromLTWH(
        offset.dx,
        offset.dy,
        _pickUp.rect.width,
        _pickUp.rect.height,
      );
      setState(() {});
      _createOverlay();
    }
  }

  Offset? startPosition;

  onPanUpdate(DragUpdateDetails _) {
    if (pickUp != null) {
      // print('panUpdate ${_.delta}');
      final rect = pickUp!.rect;
      pickUp!.rect = Rect.fromLTWH(
        rect.left + _.delta.dx,
        rect.top + _.delta.dy,
        rect.width,
        rect.height,
      );

      final entryIndex = findSlotByOffset(_.globalPosition);
      if (entryIndex != -1) {
        final entry = _relationship.entries.elementAt(entryIndex);
        final slot = entry.key;
        // print('panUpdate $_fromSlot $slot');
        final value = entry.value;
        if ((value == null || value.currentState?.item?.fixed == false) &&
            slot != _fromSlot) {
          _dragTo(slot);
        }
      }
    }
  }

  onPanEnd(_) {
    if (pickUp != null) {
      print('panEnd');
      final _pickUp = this.pickUp!;
      final _fromSlot = this._fromSlot!;
      _children.add(_pickUp.widget);
      this.pickUp = null;
      this._fromSlot = null;
      final offset = _pickUp.rect.topLeft - _dragOffset;
      _pickUp.rect = Rect.fromLTWH(
        offset.dx,
        offset.dy,
        _pickUp.rect.width,
        _pickUp.rect.height,
      );
      SchedulerBinding.instance?.addPostFrameCallback((timeStamp) {
        _pickUp.dragging = false;
        _pickUp.rect = Rect.fromLTWH(
          _fromSlot.currentState!.rect.left,
          _fromSlot.currentState!.rect.top,
          _fromSlot.currentState!.rect.width,
          _fromSlot.currentState!.rect.height,
        );
      });
      _relationship[_fromSlot] = _pickUp.widget.key;
      _createOverlay();
      setState(() {});
    }

    widget.onChange?.call(items);
  }

  late Offset longPressPosition;

  onLongPressStart(LongPressStartDetails _) {
    // print('onLongPressStart');
    editMode = true;
    longPressPosition = _.localPosition;
    onPanStart(DragStartDetails(globalPosition: _.globalPosition));
  }

  onLongPressMoveUpdate(LongPressMoveUpdateDetails _) {
    // print('onLongPressMoveUpdate');
    onPanUpdate(DragUpdateDetails(
      globalPosition: _.globalPosition,
      delta: _.localPosition - longPressPosition,
      localPosition: _.localPosition,
    ));
    longPressPosition = _.localPosition;
  }

  onLongPressEnd(_) {
    onPanEnd(null);
  }

  void _dragTo(GlobalKey<DraggableSlotState<T>> toSlot) {
    if (_fromSlot == null || _fromSlot == toSlot) return;
    final slots = _relationship.keys.toList();
    final fromIndex = slots.indexOf(_fromSlot!),
        toIndex = slots.indexOf(toSlot);
    final start = math.min(fromIndex, toIndex),
        end = math.max(fromIndex, toIndex);
    final T? fromItem = items[fromIndex];
    // items[fromIndex] = null;
    if (end - start == 1) {
      // 前后交换
      print('前后位置交换： $start to $end');
      _relationship[toSlot]?.currentState?.rect = _fromSlot!.currentState!.rect;
      _relationship[_fromSlot!] = _relationship[toSlot];
      items[fromIndex] = items[toIndex];
      items[toIndex] = fromItem;
      _fromSlot = toSlot;
    } else if (end - start > 1) {
      // 多个交换
      _relationship[_fromSlot!] = null;
      if (fromIndex == start) {
        // 从前往后拖动
        print('从前往后拖动： $start to $end');
        items[fromIndex] = null;
        reorder(start: start, end: end);
        items[toIndex] = fromItem;
      } else {
        print('从后往前拖动： $start to $end');
        items[fromIndex] = null;
        reorder(start: start, end: end, reverse: true);
        items[toIndex] = fromItem;
      }
      // _fromSlot = toSlot;
      // items[toIndex] = fromItem;
    }
  }

  void reorder({int start: 0, int end: -1, reverse: false}) {
    if (end == -1 || end > items.length) end = items.length;
    var entries = _relationship.entries.toList();
    var _items = items.toList();
    if (reverse) {
      entries = entries.reversed.toList();
      _items = _items.reversed.toList();
      var _start = _items.length - start - 1;
      end = _items.length - end - 1;
      start = end;
      end = _start;
    }
    print('reverse:$reverse, $start to $end');
    for (var i = start; i < end; i++) {
      final entry = entries[i];
      final slot = entry.key;
      final item = _items[i];
      print('i $i $item');
      if (item == null) {
        int next = -1;
        for (var j = i; j < end; j++) {
          print('j $j');
          if (_items[j]?.fixed == false) {
            next = j;
            break;
          }
        }
        print('next $next');
        if (next == -1) {
          break;
        } else {
          final nextSlot = _fromSlot = entries[next].key;
          final nextItem = entries[next].value;
          _relationship[slot] = nextItem;
          _items[i] = _items[next];
          _items[next] = null;
          if (nextItem != null && nextItem.currentState != pickUp)
            nextItem.currentState?.rect = slot.currentState!.rect;
          _relationship[nextSlot] = null;
        }
      }
    }
    if (reverse) _items = _items.reversed.toList();
    items
      ..clear()
      ..addAll(_items);
  }

  int findPreviousDraggableItem({
    required int start,
    int end = -1,
  }) {
    if (end == -1) end = items.length - 1;
    for (var i = end; i > 0; i--) {
      if (items[i]?.fixed == false) return i;
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    print('build children.length:${_children.length}');
    Widget child = RawGestureDetector(
      gestures: _gestures,
      child: LayoutBuilder(
        builder: (_, BoxConstraints constraints) {
          final _layoutWidth = constraints.maxWidth == double.infinity
              ? MediaQuery.of(context).size.width.roundToDouble()
              : constraints.maxWidth.roundToDouble();
          if (_layoutWidth != layoutWidth) {
            layoutWidth = _layoutWidth;
            print('layoutBuild $layoutWidth');
            calcItemSize(widget.gridDelegate, layoutWidth);
            _createSlots();
            _updateSlots();
          }
          // 容器高度
          final height = constraints.maxHeight == double.infinity
              ? _maxHeight
              : constraints.maxHeight;
          // print('容器高度 $height');
          return Container(
            height: height,
            child: Stack(
              key: _stackKey,
              clipBehavior: Clip.none,
              children: [
                ..._slots,
                ..._children,
              ],
            ),
          );
        },
      ),
    );
    if (widget.padding != null)
      child = Padding(padding: widget.padding!, child: child);
    return child;
  }

  DraggableSlot<T> _createSlot({
    required int index,
    required T? item,
    required Rect rect,
  }) {
    return DraggableSlot<T>(
      key: GlobalKey<DraggableSlotState<T>>(),
      item: item,
      rect: rect,
      duration: widget.animationDuration,
      slot: widget.slotBuilder?.call(context, item, index) ??
          Container(
            decoration: BoxDecoration(
              // borderRadius: BorderRadius.all(Radius.circular(10)),
              border: Border.all(
                width: 4,
                color: Colors.blue,
              ),
            ),
            child: Center(child: Text(_relationship.keys.length.toString())),
          ),
    );
  }

  GlobalKey<DraggableSlotState<T>>? findSlotFromItemState(
      DraggableWidgetState<T>? state) {
    if (state == null) return null;
    final index = _relationship.values.toList().indexOf(state.widget.key);
    if (index > -1) return _relationship.keys.elementAt(index);
  }

  void addSlot(T? item, {bool update = true}) {
    final index = items.length;
    items.add(item);
    final Rect rect = calcSlotRect(index: index, layoutWidth: layoutWidth);
    final slot = _createSlot(index: index, item: item, rect: rect);
    final child = _createItem(index: index, item: item, rect: rect);
    if (child != null) {
      _children.add(child);
    }
    _slots.add(slot);
    _relationship[slot.key] = child?.key;

    if (mounted && update) {
      _updateSlots();
      setState(() {});
    }
    widget.onChange?.call(items.toList());
  }

  void insertSlot(int index, T? item, {bool update = true}) {
    print('insertSlot $index');
    items.insert(index, item);
    final entry = _create(index, item);
    if (entry.value != null) {
      _children.add(entry.value!);
    }
    _slots.insert(index, entry.key);
    final keys = _relationship.keys.toList();
    final values = _relationship.values.toList();
    keys.insert(index, entry.key.key);
    values.insert(index, entry.value?.key);
    final Iterable<
        MapEntry<GlobalKey<DraggableSlotState<T>>,
            GlobalKey<DraggableWidgetState<T>>?>> entries = Iterable.generate(
      keys.length,
      (index) => MapEntry(keys[index], values[index]),
    );

    _relationship
      ..clear()
      ..addEntries(entries);
    if (mounted && update) {
      _updateSlots();
      setState(() {});
    }
    widget.onChange?.call(items.toList());
  }

  void removeSlot(int index) {
    final key = _relationship.keys.elementAt(index);
    _relationship.remove(key);
    _slots.remove(key.currentWidget);
    if (mounted) {
      _updateSlots();
      setState(() {});
    }
    widget.onChange?.call(items.toList());
  }

  void replaceItem(int index, T? item) {
    assert(
      index.clamp(0, items.length - 1) == index,
      'Out of items range [${0}-${items.length}]:$index',
    );
    items[index] = item;
    final slot = _relationship.keys.elementAt(index);
    if (_relationship[slot] != null) {
      _children.remove(_relationship[slot]!.currentWidget);
    }
    final child =
        _createItem(index: index, item: item, rect: slot.currentState!.rect);
    if (child != null) {
      _children.add(child);
    }
    _relationship[slot] = child?.key;
    widget.onChange?.call(items.toList());
    if (mounted) {
      _updateSlots();
      setState(() {});
    }
  }

  int removeItem(T item) {
    final index = items.indexOf(item);
    if (index > -1) {
      removeItemAt(index);
    }
    return index;
  }

  T? removeItemAt(int index) {
    assert(
      index.clamp(0, items.length - 1) == index,
      'Out of items range [${0}-${items.length}]:$index',
    );
    final item = items[index];
    final slot = _relationship.keys.elementAt(index);
    final child = _relationship[slot];
    items[index] = null;
    _relationship[slot] = null;
    widget.onChange?.call(items.toList());
    _children.remove(child?.currentWidget);
    reorder();
    if (mounted) {
      _updateSlots();
      setState(() {});
    }
    widget.onChange?.call(items.toList());
    return item;
  }

  MapEntry<DraggableSlot<T>, DraggableWidget<T>?> _create(int index, T? item) {
    final Rect rect = calcSlotRect(index: index, layoutWidth: layoutWidth);
    final slot = _createSlot(index: index, item: item, rect: rect);
    final child = _createItem(index: index, item: item, rect: rect);
    return MapEntry(slot, child);
  }
}
