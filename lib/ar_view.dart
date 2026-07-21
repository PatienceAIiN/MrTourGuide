import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';

import 'constant.dart';
import 'services/haptic_service.dart';

class _ArModel {
  final String label;
  final String src;
  final String note;
  const _ArModel(this.label, this.src, this.note);
}

/// Embedded 3D/AR viewer with selectable models.
///
/// "Test" models verify the pipeline end-to-end (one bundled/offline, one
/// streamed HD). On a phone the AR button hands off to Scene Viewer so the
/// model is placed in the real room via the camera — that's the "for real"
/// path; on desktop web you get full orbit/zoom 3D.
class ArViewPage extends StatefulWidget {
  final String title;

  const ArViewPage({super.key, this.title = 'MR/VR Experience'});

  @override
  State<ArViewPage> createState() => _ArViewPageState();
}

class _ArViewPageState extends State<ArViewPage> {
  static const models = [
    _ArModel(
      'Astronaut · test',
      'assets/models/astronaut.glb',
      'Bundled test model — works offline. Drag to orbit, scroll to zoom.',
    ),
    _ArModel(
      'Helmet · HD test',
      'https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Models/master/2.0/DamagedHelmet/glTF-Binary/DamagedHelmet.glb',
      'Streamed HD test — checks network 3D loading and PBR materials.',
    ),
  ];

  int selected = 0;

  @override
  Widget build(BuildContext context) {
    final model = models[selected];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: Colors.purple,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Expanded(
            child: ModelViewer(
              key: ValueKey(model.src),
              src: model.src,
              alt: 'A 3D model you can rotate, zoom and view in AR',
              backgroundColor: const Color(0xFF101014),
              cameraControls: true,
              autoRotate: true,
              ar: true,
              arModes: const ['scene-viewer', 'webxr', 'quick-look'],
            ),
          ),
          Container(
            width: double.infinity,
            color: const Color(0xFF17171C),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: SafeArea(
              top: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      for (var i = 0; i < models.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(models[i].label),
                            selected: selected == i,
                            selectedColor: Colors.purple,
                            labelStyle: TextStyle(
                              color: selected == i
                                  ? Colors.white
                                  : Colors.white70,
                              fontSize: 12.5,
                            ),
                            backgroundColor: const Color(0xFF26262E),
                            onSelected: (_) {
                              Haptics.tick();
                              setState(() => selected = i);
                            },
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    model.note,
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 12, height: 1.4),
                  ),
                  const SizedBox(height: 6),
                  const Row(
                    children: [
                      Icon(Icons.view_in_ar, color: lightBlue, size: 15),
                      SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'On your phone, tap the AR button in the viewer to '
                          'place this in your room — real camera MR. Creator '
                          'VR/MR captures play from Explore.',
                          style: TextStyle(
                              color: Colors.white38,
                              fontSize: 11,
                              height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
