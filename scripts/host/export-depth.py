#!/usr/bin/env python3
"""Export Depth Anything V2 Metric Small, the indoor model, to ONNX for the
Nano's TensorRT, with indoor test pictures and PyTorch's depth for them, as a
bundle for setup-depth.sh and probe-depth-trt.sh.

The model (github.com/DepthAnything/Depth-Anything-V2, metric_depth, Apache-2.0)
gives each pixel's distance from the camera in metres, up to 20 m, from one
picture; its indoor weights were fine-tuned on the Hypersim dataset. Runs on a
PC (not the Nano), in export-yolo26.py's Python environment (CPU PyTorch with
torchvision, onnx, onnxslim, onnxruntime, OpenCV; Ultralytics is not used):
  ENV/bin/python scripts/host/export-depth.py [OUT]

OUT is artifacts/depth by default (out of git: the models are binaries). It
gets the model's code at a pinned commit (src/), its weights and three of its
indoor example pictures (downloads/), each checked against its SHA-256, the
bundle folder and OUT/depth-nano.tar holding it:
  models/da2s-indoor-WxH.onnx              at 336x252, 280x210 and 448x336
  models/da2s-indoor-336x252-convln.onnx   LayerNorm without Reduce operators
  models/da2s-indoor-336x252-plainln.onnx  PyTorch's own LayerNorm pieces
  models/da2s-indoor-336x252-tokens.onnx   the transformer as DINOv2 writes it
  probes/<part>.onnx                       pieces of the first transformer
                                           block, in either layout
  test/<picture>-640x480.png               demo10, demo13 and demo15, cut to 4:3
  test/<picture>.WxH.npy                   PyTorch's depth for it at that size
                                           (float32 metres, H x W)
  SHA256SUMS, README.txt
Each model takes an RGB picture, 0 to 1, of its own size, (1, 3, H, W), and
gives depth in metres, (1, H, W); the ImageNet normalization is inside. The
sizes are 4:3 like the webcam's 640x480 and multiples of 14, the model's patch
size. ONNX opset 13 (the newest TensorRT 8.2 reads), simplified, FP32 (the Nano
builds FP16 engines from it). Changes that fit the graph to TensorRT 8.2
without changing its result:
  - Convolution layout. TensorRT 8.2 on the Nano builds no engine from the
    transformer as DINOv2 writes it, tokens as (1, N, C) rows through matrix
    products, in FP16 or FP32: it hands the whole transformer to its Myelin
    compiler, which finds no implementation for it (setup-depth.sh,
    2026-10-19). Here the tokens are a (1, C, 1, N) feature map, as YOLO26's
    attention lays them out, which TensorRT 8.2 built from its own layers:
    every linear layer is a 1x1 convolution, attention multiplies 4-D
    tensors, and LayerNorm works across channels. The -tokens model keeps
    DINOv2's layout, for TensorRT 8.5.
  - DINOv2 resizes its position embedding (bicubic, which TensorRT 8.2's Resize
    lacks) to the input size on every run; here it is resized once and stored.
  - Opset 13 has no LayerNormalization, so PyTorch writes it as its pieces,
    which square x - mean: in FP16 that overflows once |x - mean| passes 255.9.
    The models compute it on x / max|x| per token, so every square stays at
    most 4. The -plainln model keeps PyTorch's pieces, to test on the Nano
    whether that matters; the -convln model takes its means with a 1x1
    convolution instead of a Reduce operator, on x / s for a fixed s per
    LayerNorm from the test pictures, in case Reduce is what TensorRT 8.2
    hands to Myelin.
The probes are the first block's pieces, at 336x252's 433 tokens, each in both
layouts (tokens-*: DINOv2's, conv-*: the models'), for probe-depth-trt.sh to
find which ones TensorRT builds with its own layers.

Checks, each a line, then EXPORT=PASS or FAIL: the SHA-256 values; that each
changed model gives the original's depth (AbsRel PATCH_TOL or less); each
model's input, output and operators (only those in TRT_OPS) and, in the
convolution layout, no matrix product with weights and no Gather; that ONNX
Runtime gives PyTorch's depth through depth-cam.py's preparation of the
pictures (AbsRel ORT_TOL or less); and each probe's operators and its ONNX
Runtime result against PyTorch's. Informational: the depth range per picture
and the largest |x - mean| that reaches a LayerNorm.
"""
import hashlib
import importlib.util
import pathlib
import shutil
import sys
import tarfile
import tempfile
import urllib.request

COMMIT = 'a561b849ebae10a6f5ef49e26c83cbbcd36c71bf'  # Depth-Anything-V2, 2025-06-30
CODE_URL = f'https://raw.githubusercontent.com/DepthAnything/Depth-Anything-V2/{COMMIT}/'
SOURCES = {  # the metric model's code at COMMIT
    'metric_depth/depth_anything_v2/dinov2.py': '0ceeaecd4e8026f8218694014642515fb7a0943c1833b75edc91ae7a79ac9690',
    'metric_depth/depth_anything_v2/dinov2_layers/__init__.py': 'e3c28c7b775165b6844000eb69f44d104d6c3803ac7da5d59f6ac3ecfb46d9d8',
    'metric_depth/depth_anything_v2/dinov2_layers/attention.py': '0d2410ce8b8b4499a6b0cdab939ae2bceab8971efd8660d999b0f3088f28cbf7',
    'metric_depth/depth_anything_v2/dinov2_layers/block.py': '093266ea08084c7cce7b8ddd779ecfaaa13055735faa8a7d68b5924f385b395b',
    'metric_depth/depth_anything_v2/dinov2_layers/drop_path.py': '949100aac4d9c19c9d65319dbd362886c5d46a72d7586ba4fd500e9f1d51570c',
    'metric_depth/depth_anything_v2/dinov2_layers/layer_scale.py': '356817b5d1390737128cbcc03a5333fd3060b73beae478772282ccb851d0ef85',
    'metric_depth/depth_anything_v2/dinov2_layers/mlp.py': 'c18c5b3f021408597a473bb710070ec3fb3b39f5a2e42e88ae83ced425a608b5',
    'metric_depth/depth_anything_v2/dinov2_layers/patch_embed.py': 'b3f82e19926c9cfb63f10136aca5e8a723bde1ad62dae1d04f90d405f9439baf',
    'metric_depth/depth_anything_v2/dinov2_layers/swiglu_ffn.py': 'df81d9901240214edc1831ce1b77558dcd6227b29a2f000fc5f546df55d2d09a',
    'metric_depth/depth_anything_v2/dpt.py': '120698fd0ad9a4d169b4b9ef26035ad0cb11eed4089af53e07e38f5717024b1d',
    'metric_depth/depth_anything_v2/util/blocks.py': '351aa24b8af4bef923ebe3bed5e5e8503b08e39bf06ee045d6444a485a2036a8',
    'metric_depth/depth_anything_v2/util/transform.py': 'a97df1dbb687457a40c387fdc3482edee7ddc5c142c7d2735ca6235a8ae2885f',
}
PICTURES = {  # indoor examples from the repository's assets at COMMIT
    'demo10': 'bc77f215081f58de8d079e821e2808f6ee2727dfa729c10a5921c186a32c7638',  # a room with windows
    'demo13': '9168fc752a002d50138a56621e8de5fab7fed125a978dd293319d28d30993564',  # a museum showcase
    'demo15': 'bf60ce3879f627e8886280cc61442174c91908894a5b059681341fed600f7db3',  # a hall with a staircase
}
WEIGHTS = 'depth_anything_v2_metric_hypersim_vits.pth'
WEIGHTS_SHA256 = 'b782898d8a3e8be1f639de33837ed85e9b4b73e40f8f5e5cd99067588d722545'  # 99,222,290 bytes
WEIGHTS_URL = f'https://huggingface.co/depth-anything/Depth-Anything-V2-Metric-Hypersim-Small/resolve/main/{WEIGHTS}'
MAX_DEPTH = 20.0  # metres: the indoor model's range
SIZES = ((336, 252), (280, 210), (448, 336))  # width, height: 4:3, multiples of 14; the first is the default
VARIANT = (336, 252)  # also exported as -convln, -plainln and -tokens; the probes' token count
PICTURE_SIZE = (640, 480)
MEAN, STD = (0.485, 0.456, 0.406), (0.229, 0.224, 0.225)  # ImageNet's, as the model was trained
OPSET = 13  # TensorRT 8.2's newest
PATCH_TOL = 1e-4
ORT_TOL = 1e-3
PROBE_TOL = 1e-4       # largest difference, relative to the largest value, of a probe from ONNX Runtime
CONVLN_SPREAD = 8.0    # -convln's |x - mean| / s on the test pictures, at most; FP16 overflows past 255.9
# Operators the models may use, each taken by TensorRT 8.2's ONNX parser (onnx-tensorrt
# release/8.2-GA, docs/operators.md) with linear or nearest Resize only; not Reciprocal, which it lacks.
TRT_OPS = {'Abs', 'Add', 'Clip', 'Concat', 'Conv', 'ConvTranspose', 'Div', 'Erf', 'Gather', 'Gemm', 'MatMul', 'Max',
           'Mul', 'Pow', 'ReduceMax', 'ReduceMean', 'Relu', 'Reshape', 'Resize', 'Sigmoid', 'Slice', 'Softmax',
           'Split', 'Sqrt', 'Squeeze', 'Sub', 'Transpose', 'Unsqueeze'}

here = pathlib.Path(__file__).resolve().parent
repo = here.parent.parent
failures = []


def check(name, ok, detail=''):
    print(f'{name}={"PASS" if ok else "FAIL"}{" " + detail if detail else ""}', flush=True)
    if not ok:
        failures.append(name)
    return ok


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def fetch(url, path, want):
    """path, downloaded from url unless it is there already, if its SHA-256 is want."""
    if not path.exists() or sha256(path) != want:
        print(f'downloading {url}', flush=True)
        path.parent.mkdir(parents=True, exist_ok=True)
        part = path.with_name(path.name + '.part')
        with urllib.request.urlopen(url, timeout=120) as r, open(part, 'wb') as f:
            shutil.copyfileobj(r, f)
        part.replace(path)
    return sha256(path) == want


def load_depth_cam():
    spec = importlib.util.spec_from_file_location('depth_cam', repo / 'scripts/jetson/yolo/depth-cam.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else repo / 'artifacts/depth').resolve()
    import cv2
    import numpy as np
    import onnx
    import onnxruntime
    import onnxslim
    import torch
    import torch.nn.functional as F

    dcam = load_depth_cam()
    src, downloads = out / 'src' / COMMIT[:7], out / 'downloads'
    bad = [name for name, want in SOURCES.items() if not fetch(CODE_URL + name, src / name, want)]
    check('SOURCES', not bad, f'{len(SOURCES)} files at {COMMIT[:7]}' + (f'; wrong: {bad}' if bad else ''))
    bad = [p for p, want in PICTURES.items()
           if not fetch(f'{CODE_URL}assets/examples/{p}.jpg', downloads / f'{p}.jpg', want)]
    check('PICTURES', not bad, ', '.join(PICTURES) + (f'; wrong: {bad}' if bad else ''))
    weights = downloads / WEIGHTS
    check(f'WEIGHTS_{WEIGHTS}', fetch(WEIGHTS_URL, weights, WEIGHTS_SHA256), sha256(weights))
    if failures:
        print(f'EXPORT=FAIL {" ".join(failures)}')
        return 1

    sys.path.insert(0, str(src / 'metric_depth'))
    import depth_anything_v2.dinov2_layers.attention as attention
    from depth_anything_v2.dpt import DepthAnythingV2
    attention.XFORMERS_AVAILABLE = False  # PyTorch's own attention, which exports

    def load_model():
        model = DepthAnythingV2(encoder='vits', features=64, out_channels=[48, 96, 192, 384], max_depth=MAX_DEPTH)
        model.load_state_dict(torch.load(weights, map_location='cpu', weights_only=True))
        return model.eval()

    class Nano(torch.nn.Module):
        """RGB 0 to 1, (1, 3, H, W), to metres, (1, H, W): the model with its normalization."""

        def __init__(self, model):
            super().__init__()
            self.model = model
            self.register_buffer('mean', torch.tensor(MEAN).view(1, 3, 1, 1))
            self.register_buffer('std', torch.tensor(STD).view(1, 3, 1, 1))

        def forward(self, x):
            return self.model((x - self.mean) / self.std)

    class SafeLayerNorm(torch.nn.Module):
        """nn.LayerNorm over the last axis, computed on x / max|x| (the same
        result, as the scale cancels): every value is then within 1, every
        square of x - mean within 4, so FP16 cannot overflow."""

        def __init__(self, norm):
            super().__init__()
            self.weight, self.bias = norm.weight, norm.bias
            self.register_buffer('eps', torch.tensor(norm.eps))  # a tensor: a number over m exports as Reciprocal

        def forward(self, x):
            m = x.abs().amax(-1, keepdim=True).clamp(min=1e-2)  # eps / m^2 stays within FP16 too
            x = x / m
            d = x - x.mean(-1, keepdim=True)
            v = (d * d).mean(-1, keepdim=True)
            return d / torch.sqrt(v + self.eps / m / m) * self.weight + self.bias

    def tokens_for_nano(size):
        """The model in DINOv2's layout for one input size: its position embedding stored, SafeLayerNorm."""
        model = load_model()
        vit = model.pretrained
        w, h = size
        tokens = torch.zeros(1, 1 + (h // 14) * (w // 14), vit.embed_dim)
        with torch.no_grad():
            stored = vit.interpolate_pos_encoding(tokens, h, w).clone()  # (x, w, h) there means (x, height, width)
        vit.register_buffer('pos_embed_stored', stored)

        def stored_pos(x, w, h):
            assert x.shape[1] == stored.shape[1], 'the model was exported for another size'
            return vit.pos_embed_stored
        vit.interpolate_pos_encoding = stored_pos
        for parent in list(vit.modules()):
            for name, child in list(parent.named_children()):
                if isinstance(child, torch.nn.LayerNorm):
                    setattr(parent, name, SafeLayerNorm(child))
        return Nano(model).eval()

    # The convolution layout: tokens as a (1, C, 1, N) feature map, the class token first.
    def conv1x1(linear):
        conv = torch.nn.Conv2d(linear.in_features, linear.out_features, 1)
        conv.weight = torch.nn.Parameter(linear.weight.detach()[:, :, None, None].clone())
        conv.bias = torch.nn.Parameter(linear.bias.detach().clone())
        return conv

    def channels(vector):
        return vector.detach().view(1, -1, 1, 1).clone()

    class ChannelNorm(torch.nn.Module):
        """A ViT's LayerNorm across the channels of (1, C, 1, N). kind:
        safe   on x / max|x| per token, as SafeLayerNorm;
        plain  PyTorch's pieces;
        conv   no Reduce operator: each mean is a 1x1 convolution with weights
               1/C, on x / scale (scale fixed from the test pictures)."""

        def __init__(self, norm, kind, scale=1.0):
            super().__init__()
            self.kind = kind
            self.register_buffer('weight', channels(norm.weight))
            self.register_buffer('bias', channels(norm.bias))
            self.register_buffer('eps', torch.tensor(norm.eps / scale / scale if kind == 'conv' else norm.eps))
            self.register_buffer('inv_scale', torch.tensor(1 / scale))
            c = norm.weight.numel()
            self.register_buffer('average', torch.full((1, c, 1, 1), 1 / c))

        def forward(self, x):
            eps = self.eps
            if self.kind == 'conv':
                x = x * self.inv_scale
                d = x - F.conv2d(x, self.average)
                return d / torch.sqrt(F.conv2d(d * d, self.average) + eps) * self.weight + self.bias
            if self.kind == 'safe':
                m = x.abs().amax(1, keepdim=True).clamp(min=1e-2)
                x = x / m
                eps = eps / m / m
            d = x - x.mean(1, keepdim=True)
            return d / torch.sqrt((d * d).mean(1, keepdim=True) + eps) * self.weight + self.bias

    class ConvBlock(torch.nn.Module):
        """A DINOv2 block in the convolution layout: attention as in YOLO26."""

        def __init__(self, block, kind, scales):
            super().__init__()
            assert isinstance(block.ls1.gamma, torch.Tensor) and isinstance(block.ls2.gamma, torch.Tensor)
            self.norm1 = ChannelNorm(block.norm1, kind, scales[0])
            self.norm2 = ChannelNorm(block.norm2, kind, scales[1])
            self.qkv, self.proj = conv1x1(block.attn.qkv), conv1x1(block.attn.proj)
            self.fc1, self.act, self.fc2 = conv1x1(block.mlp.fc1), block.mlp.act, conv1x1(block.mlp.fc2)
            self.heads, self.scale = block.attn.num_heads, block.attn.scale
            self.register_buffer('gamma1', channels(block.ls1.gamma))
            self.register_buffer('gamma2', channels(block.ls2.gamma))

        def attention(self, x):
            b, c, _, n = x.shape
            q, k, v = self.qkv(x).reshape(b, 3 * self.heads, c // self.heads, n).split(self.heads, 1)
            attn = ((q * self.scale).transpose(-2, -1) @ k).softmax(-1)
            return self.proj((v @ attn.transpose(-2, -1)).reshape(b, c, 1, n))

        def mlp(self, x):
            return self.fc2(self.act(self.fc1(x)))

        def forward(self, x):
            x = x + self.attention(self.norm1(x)) * self.gamma1
            return x + self.mlp(self.norm2(x)) * self.gamma2

    class ConvForm(torch.nn.Module):
        """DepthAnythingV2.forward in the convolution layout, for one input size."""

        def __init__(self, model, size, kind, scale):
            super().__init__()
            vit, (w, h) = model.pretrained, size
            assert vit.num_register_tokens == 0 and not vit.chunked_blocks
            self.patch = vit.patch_embed.proj
            tokens = torch.zeros(1, 1 + (h // 14) * (w // 14), vit.embed_dim)
            with torch.no_grad():
                pos = vit.interpolate_pos_encoding(tokens, h, w)  # (x, w, h) there means (x, height, width)
            self.register_buffer('pos', pos.permute(0, 2, 1)[:, :, None].clone())
            self.register_buffer('cls', vit.cls_token.detach().permute(0, 2, 1)[:, :, None].clone())
            self.blocks = torch.nn.ModuleList(
                ConvBlock(b, kind, (scale(f'blocks.{i}.norm1'), scale(f'blocks.{i}.norm2')))
                for i, b in enumerate(vit.blocks))
            self.norm = ChannelNorm(vit.norm, kind, scale('norm'))
            self.take = model.intermediate_layer_idx[model.encoder]
            self.head, self.max_depth = model.depth_head, model.max_depth
            assert not self.head.use_clstoken

        def forward(self, x):
            t = self.patch(x)
            b, c, h, w = t.shape
            t = torch.cat([self.cls, t.reshape(b, c, 1, h * w)], 3) + self.pos
            maps = []
            for i, block in enumerate(self.blocks):
                t = block(t)
                if i in self.take:
                    maps.append(self.norm(t)[..., 1:].reshape(b, c, h, w))
            head, s = self.head, self.head.scratch
            out = [head.resize_layers[i](head.projects[i](m)) for i, m in enumerate(maps)]
            l1, l2, l3, l4 = s.layer1_rn(out[0]), s.layer2_rn(out[1]), s.layer3_rn(out[2]), s.layer4_rn(out[3])
            p = s.refinenet4(l4, size=l3.shape[2:])
            p = s.refinenet3(p, l3, size=l2.shape[2:])
            p = s.refinenet2(p, l2, size=l1.shape[2:])
            p = s.refinenet1(p, l1)
            p = F.interpolate(s.output_conv1(p), (h * 14, w * 14), mode='bilinear', align_corners=True)
            return (s.output_conv2(p) * self.max_depth).squeeze(1)

    def conv_for_nano(size, kind):
        """The model in the convolution layout for one input size, with LayerNorm of that kind."""
        return Nano(ConvForm(load_model(), size, kind, convln_scale)).eval()

    class Part(torch.nn.Module):
        """One method of a module, as a module of its own, for a probe."""

        def __init__(self, module, method):
            super().__init__()
            self.module, self.method = module, method

        def forward(self, x):
            return getattr(self.module, self.method)(x)

    reference = Nano(load_model()).eval()  # unchanged: position embedding resized on the fly, nn.LayerNorm
    bundle = out / 'depth-nano'
    if bundle.exists():
        shutil.rmtree(bundle)
    for d in (bundle / 'models', bundle / 'test'):
        d.mkdir(parents=True)

    # Test pictures: the middle 4:3 of each, at 640x480 like the webcam's frames.
    pictures = {}
    for name in PICTURES:
        img = cv2.imread(str(downloads / f'{name}.jpg'), cv2.IMREAD_COLOR)
        h, w = img.shape[:2]
        cw, ch = min(w, h * 4 // 3), min(h, w * 3 // 4)
        img = img[(h - ch) // 2:(h - ch) // 2 + ch, (w - cw) // 2:(w - cw) // 2 + cw]
        png = bundle / 'test' / f'{name}-640x480.png'
        cv2.imwrite(str(png), cv2.resize(img, PICTURE_SIZE, interpolation=cv2.INTER_AREA))
        pictures[name] = cv2.imread(str(png), cv2.IMREAD_COLOR)  # exactly what the Nano reads

    # PyTorch's depth through depth-cam.py's preparation, and the largest x - mean reaching each LayerNorm.
    names = {m: n for n, m in reference.model.pretrained.named_modules() if isinstance(m, torch.nn.LayerNorm)}
    spread = dict.fromkeys(names.values(), 0.0)

    def watch(module, inputs):
        x = inputs[0]
        spread[names[module]] = max(spread[names[module]], float((x - x.mean(-1, keepdim=True)).abs().max()))
    hooks = [m.register_forward_pre_hook(watch) for m in names]
    blobs, depths = {}, {}
    with torch.no_grad():
        for size in SIZES:
            for name, img in pictures.items():
                blob = dcam.prepare(img, size)
                depth = reference(torch.from_numpy(blob))[0].numpy().astype(np.float32)
                blobs[size, name], depths[size, name] = blob, depth
                np.save(bundle / 'test' / f'{name}.{size[0]}x{size[1]}.npy', depth)
                print(f'DEPTH {name} {size[0]}x{size[1]}: {depth.min():.2f} to {depth.max():.2f} m, '
                      f'median {np.median(depth):.2f}', flush=True)
    for hook in hooks:
        hook.remove()

    def convln_scale(name):
        """-convln's fixed divisor for the LayerNorm of that name in DINOv2."""
        return max(1.0, spread[name] / CONVLN_SPREAD)
    widest = max(spread.values())
    scales = [convln_scale(name) for name in spread]
    print(f'LAYERNORM largest |x - mean| {widest:.1f} on the test pictures'
          f' ({"over" if widest > 255.9 else "within"} FP16\'s 255.9 for its square);'
          f' -convln divides by {min(scales):.1f} to {max(scales):.1f}', flush=True)

    def error(found):
        """AbsRel, or infinity when any value is not a number."""
        return float('inf') if found['nonfinite'] else found['abs_rel']

    def to_onnx(module, example, path, tmp, inputs, outputs):
        """module exported for example, simplified, checked and saved to path."""
        raw = pathlib.Path(tmp) / path.name
        torch.onnx.export(module, example, str(raw), opset_version=OPSET, input_names=inputs, output_names=outputs,
                          do_constant_folding=True, dynamo=False)
        graph = onnxslim.slim(onnx.load(str(raw)))
        onnx.save(graph, str(path))
        onnx.checker.check_model(graph)
        return graph

    def ops_check(name, graph):
        ops = {n.op_type for n in graph.graph.node}
        resize = {a.s.decode() for n in graph.graph.node if n.op_type == 'Resize' for a in n.attribute
                  if a.name == 'mode'}
        return check(name, ops <= TRT_OPS and resize <= {'linear', 'nearest'} and graph.opset_import[0].version == OPSET,
                     f'opset {graph.opset_import[0].version}, {len(graph.graph.node)} nodes, Resize {sorted(resize)}'
                     + (f', not expected: {sorted(ops - TRT_OPS)}' if ops - TRT_OPS else ''))

    def form_check(name, graph):
        """The convolution layout: no matrix product with weights, no Gather."""
        weights = {i.name for i in graph.graph.initializer}
        products = [n for n in graph.graph.node if n.op_type in ('MatMul', 'Gemm')]
        weighted = [n.name for n in products if weights & set(n.input)]
        gathers = sum(n.op_type == 'Gather' for n in graph.graph.node)
        return check(name, not weighted and not gathers,
                     f'{len(products)} matrix products, {len(weighted)} with weights, {gathers} Gather'
                     + (f': {weighted[:3]}' if weighted else ''))

    v = f'da2s-indoor-{VARIANT[0]}x{VARIANT[1]}'
    exports = [(f'da2s-indoor-{w}x{h}', (w, h), 'safe') for w, h in SIZES]
    exports[1:1] = [(f'{v}-convln', VARIANT, 'conv'), (f'{v}-plainln', VARIANT, 'plain'), (f'{v}-tokens', VARIANT, 'tokens')]
    with tempfile.TemporaryDirectory() as tmp:
        for stem, size, kind in exports:
            w, h = size
            model = tokens_for_nano(size) if kind == 'tokens' else conv_for_nano(size, kind)
            with torch.no_grad():
                worst = max(error(dcam.compare(model(torch.from_numpy(blobs[size, n]))[0].numpy(), depths[size, n]))
                            for n in pictures)
            check(f'PATCH_{stem}', worst <= PATCH_TOL, f'AbsRel {worst:.2e} from the original at most')
            onnx_path = bundle / 'models' / f'{stem}.onnx'
            graph = to_onnx(model, torch.zeros(1, 3, h, w), onnx_path, tmp, ['image'], ['depth'])
            dims = lambda v: [d.dim_value for d in v.type.tensor_type.shape.dim]
            ins, outs = [dims(i) for i in graph.graph.input], [dims(o) for o in graph.graph.output]
            check(f'SHAPES_{stem}', ins == [[1, 3, h, w]] and outs == [[1, h, w]], f'in {ins}, out {outs}')
            ops_check(f'OPS_{stem}', graph)
            if kind != 'tokens':
                form_check(f'FORM_{stem}', graph)
            session = onnxruntime.InferenceSession(str(onnx_path), providers=['CPUExecutionProvider'])
            for name in pictures:
                got = session.run(None, {'image': blobs[size, name]})[0][0]
                found = dcam.compare(got, depths[size, name])
                check(f'ORT_{stem}_{name}', error(found) <= ORT_TOL,
                      f'AbsRel {error(found):.2e}, largest difference {found["max_err_m"] or 0:.4f} m'
                      + (f', {found["nonfinite"]:.2%} not a number' if found['nonfinite'] else ''))

        # Probes: the first block's pieces at VARIANT's token count, in DINOv2's layout and the models'.
        vit = load_model().pretrained
        block = vit.blocks[0]
        conv_blocks = {kind: ConvBlock(block, kind, (convln_scale('blocks.0.norm1'), convln_scale('blocks.0.norm2')))
                       for kind in ('safe', 'conv')}
        probes = {
            'tokens-linear': block.attn.qkv,  # a matrix product with weights, as DINOv2's every linear layer
            'tokens-layernorm': block.norm1,  # PyTorch's pieces, across the last axis
            'tokens-gelu': block.mlp.act,
            'tokens-attention': block.attn,  # with Gather picking q, k and v
            'tokens-block': block,
            'conv-layernorm': ChannelNorm(block.norm1, 'safe'),
            'conv-layernorm-plain': ChannelNorm(block.norm1, 'plain'),
            'conv-layernorm-convmean': ChannelNorm(block.norm1, 'conv', convln_scale('blocks.0.norm1')),
            'conv-gelu': block.mlp.act,
            'conv-mlp': Part(conv_blocks['safe'], 'mlp'),
            'conv-attention': Part(conv_blocks['safe'], 'attention'),
            'conv-block': conv_blocks['safe'],
            'conv-block-convln': conv_blocks['conv'],
        }
        torch.manual_seed(0)
        tokens = torch.randn(1, 1 + (VARIANT[0] // 14) * (VARIANT[1] // 14), vit.embed_dim)
        (bundle / 'probes').mkdir()
        for name, module in probes.items():
            x = tokens if name.startswith('tokens-') else tokens.permute(0, 2, 1)[:, :, None].contiguous()
            module.eval()
            with torch.no_grad():
                want = module(x).numpy()
            path = bundle / 'probes' / f'{name}.onnx'
            graph = to_onnx(module, x, path, tmp, ['x'], ['y'])
            got = onnxruntime.InferenceSession(str(path), providers=['CPUExecutionProvider']).run(None, {'x': x.numpy()})[0]
            diff = float(np.abs(got - want).max() / np.abs(want).max()) if got.shape == want.shape else float('inf')
            ops = sorted({n.op_type for n in graph.graph.node})
            if ops_check(f'PROBE_OPS_{name}', graph) and name.startswith('conv-'):
                form_check(f'PROBE_FORM_{name}', graph)
            check(f'PROBE_{name}', diff <= PROBE_TOL, f'{tuple(x.shape)} to {tuple(want.shape)}, ONNX Runtime {diff:.1e}'
                  f' from PyTorch; {" ".join(ops)}')

    readme = f'''Depth Anything V2 Metric Small, indoor, for the Jetson Nano's TensorRT 8.2
(jetson-ubuntu-26, scripts/host/export-depth.py)

Model: Depth Anything V2 (github.com/DepthAnything/Depth-Anything-V2 at {COMMIT[:7]},
metric_depth, Apache-2.0), ViT-S encoder, fine-tuned for metric depth on Hypersim
(indoor, up to {MAX_DEPTH:g} m): {WEIGHTS} from
huggingface.co/depth-anything/Depth-Anything-V2-Metric-Hypersim-Small (Apache-2.0),
exported to ONNX by PyTorch {torch.__version__} on a CPU: opset {OPSET}, simplified, FP32.
  models/da2s-indoor-WxH.onnx  input "image" (1, 3, H, W) RGB 0-1, output "depth"
                            (1, H, W) in metres; ImageNet normalization inside;
                            position embedding resized for WxH and stored; tokens
                            as a (1, C, 1, N) feature map, linear layers as 1x1
                            convolutions; LayerNorm across channels on x / max|x|
  models/*-convln.onnx      the same with LayerNorm's means as 1x1 convolutions
                            on x divided by a fixed scale
  models/*-plainln.onnx     the same with PyTorch's own LayerNorm pieces
  models/*-tokens.onnx      the transformer in DINOv2's own layout, (1, N, C)
  probes/*.onnx             the first block's pieces, input "x", output "y":
                            tokens-* in DINOv2's layout, conv-* in the models'
Test pictures: demo10, demo13 and demo15 from the repository's assets/examples, the
middle 4:3 of each at 640x480; WxH.npy holds PyTorch's depth for each at that size,
from the picture resized (cubic) to WxH as depth-cam.py does.
'''
    (bundle / 'README.txt').write_text(readme)
    files = sorted(p for p in bundle.rglob('*') if p.is_file() and p.name != 'SHA256SUMS')
    (bundle / 'SHA256SUMS').write_text(''.join(f'{sha256(p)}  {p.relative_to(bundle)}\n' for p in files))
    tar = out / 'depth-nano.tar'

    def plain(info):
        info.uid = info.gid = 0
        info.uname = info.gname = ''
        return info
    with tarfile.open(tar, 'w') as t:
        for p in [bundle, *sorted(bundle.rglob('*'))]:
            t.add(p, arcname=str(p.relative_to(out)), recursive=False, filter=plain)
    print(f'BUNDLE {tar} {tar.stat().st_size} bytes sha256 {sha256(tar)}')
    for p in sorted((bundle / 'models').iterdir()):
        print(f'  {p.name} {p.stat().st_size} bytes sha256 {sha256(p)}')
    print(f'EXPORT={"FAIL " + " ".join(failures) if failures else "PASS"}')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
