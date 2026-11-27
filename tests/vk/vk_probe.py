#!/usr/bin/env python3
"""Headless Vulkan probe through ctypes, for NVIDIA's Tegra Vulkan driver.

Usage: python3 -I vk_probe.py [--vulkan LIBVULKAN] [--lib-root DIR] [--any-vendor]

Loads the Vulkan loader (default libvulkan.so.1), which finds drivers through
VK_DRIVER_FILES / VK_ICD_FILENAMES or the system's icd.d folders, and checks
what a compute program needs: an instance (Vulkan 1.1, no layers, no window
system extensions), the physical devices and their properties, features and
extensions, a logical device with a compute queue, a 4 MiB host-visible
storage buffer, and a compute shader (fill.comp, compiled to SPIR-V below)
run on the GPU, every value read back and checked; then the same dispatch
50 times in one submission, for the rate at which the GPU writes memory.
Only the NVIDIA device (vendor 0x10de) is used unless --any-vendor is given.
Needs no headers, compiler or Vulkan tools, only Python's ctypes.

Prints KEY=VALUE lines; the last is PROBE=PASS or PROBE=FAIL (exit 0 or 1).
LIB= lines list the NVIDIA libraries the process mapped; with --lib-root,
LIB_MIX=FAIL means one of them came from outside that folder. Unset DISPLAY
and WAYLAND_DISPLAY first, so no window system is involved. Writes nothing.
"""
import argparse
import array
import base64
import ctypes
import os
import sys
import time

c_int32, c_uint32, c_uint64, c_float = ctypes.c_int32, ctypes.c_uint32, ctypes.c_uint64, ctypes.c_float
c_void_p, c_char_p, c_size_t, POINTER = ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER
Handle = c_uint64  # non-dispatchable handles; dispatchable ones are c_void_p

VK_SUCCESS, VK_INCOMPLETE = 0, 5
VK_API_1_1 = (1 << 22) | (1 << 12)
NVIDIA = 0x10DE
QUEUE_COMPUTE = 0x2
MEMORY_HOST_VISIBLE, MEMORY_HOST_COHERENT = 0x2, 0x4
BUFFER_STORAGE = 0x20
DESCRIPTOR_STORAGE_BUFFER = 7
STAGE_COMPUTE = 0x20
PIPELINE_BIND_COMPUTE = 1
STAGE_COMPUTE_SHADER, STAGE_HOST = 0x800, 0x4000
ACCESS_SHADER_WRITE, ACCESS_HOST_READ = 0x40, 0x2000
DEVICE_TYPES = {0: 'other', 1: 'integrated', 2: 'discrete', 3: 'virtual', 4: 'cpu'}

# fill.comp (next to this file) as SPIR-V 1.0, from glslangValidator 15.1.0:
# glslangValidator -V --target-env vulkan1.0 fill.comp; spirv-val passes.
FILL_SPV = base64.b64decode(
    'AwIjBwAAAQALAAgALgAAAAAAAAARAAIAAQAAAAsABgABAAAAR0xTTC5zdGQuNDUwAAAAAA4AAwAAAAAAAQAAAA8ABgAF'
    'AAAABAAAAG1haW4AAAAACwAAABAABgAEAAAAEQAAAEAAAAABAAAAAQAAAAMAAwACAAAAwgEAAAUABAAEAAAAbWFpbgAA'
    'AAAFAAMACAAAAGkAAAAFAAgACwAAAGdsX0dsb2JhbEludm9jYXRpb25JRAAAAAUABAARAAAAUHVzaAAAAAAGAAQAEQAA'
    'AAAAAABuAAAABgAEABEAAAABAAAAbXVsAAUAAwATAAAAAAAAAAUABAAeAAAARGF0YQAAAAAGAAQAHgAAAAAAAAB2AAAA'
    'BQADACAAAAAAAAAARwAEAAsAAAALAAAAHAAAAEcAAwARAAAAAgAAAEgABQARAAAAAAAAACMAAAAAAAAASAAFABEAAAAB'
    'AAAAIwAAAAQAAABHAAQAHQAAAAYAAAAEAAAARwADAB4AAAADAAAASAAFAB4AAAAAAAAAIwAAAAAAAABHAAQAIAAAACEA'
    'AAAAAAAARwAEACAAAAAiAAAAAAAAAEcABAAtAAAACwAAABkAAAATAAIAAgAAACEAAwADAAAAAgAAABUABAAGAAAAIAAA'
    'AAAAAAAgAAQABwAAAAcAAAAGAAAAFwAEAAkAAAAGAAAAAwAAACAABAAKAAAAAQAAAAkAAAA7AAQACgAAAAsAAAABAAAA'
    'KwAEAAYAAAAMAAAAAAAAACAABAANAAAAAQAAAAYAAAAeAAQAEQAAAAYAAAAGAAAAIAAEABIAAAAJAAAAEQAAADsABAAS'
    'AAAAEwAAAAkAAAAVAAQAFAAAACAAAAABAAAAKwAEABQAAAAVAAAAAAAAACAABAAWAAAACQAAAAYAAAAUAAIAGQAAAB0A'
    'AwAdAAAABgAAAB4AAwAeAAAAHQAAACAABAAfAAAAAgAAAB4AAAA7AAQAHwAAACAAAAACAAAAKwAEABQAAAAjAAAAAQAA'
    'ACsABAAGAAAAJwAAAAcAAAAgAAQAKQAAAAIAAAAGAAAAKwAEAAYAAAArAAAAQAAAACsABAAGAAAALAAAAAEAAAAsAAYA'
    'CQAAAC0AAAArAAAALAAAACwAAAA2AAUAAgAAAAQAAAAAAAAAAwAAAPgAAgAFAAAAOwAEAAcAAAAIAAAABwAAAEEABQAN'
    'AAAADgAAAAsAAAAMAAAAPQAEAAYAAAAPAAAADgAAAD4AAwAIAAAADwAAAD0ABAAGAAAAEAAAAAgAAABBAAUAFgAAABcA'
    'AAATAAAAFQAAAD0ABAAGAAAAGAAAABcAAACwAAUAGQAAABoAAAAQAAAAGAAAAPcAAwAcAAAAAAAAAPoABAAaAAAAGwAA'
    'ABwAAAD4AAIAGwAAAD0ABAAGAAAAIQAAAAgAAAA9AAQABgAAACIAAAAIAAAAQQAFABYAAAAkAAAAEwAAACMAAAA9AAQA'
    'BgAAACUAAAAkAAAAhAAFAAYAAAAmAAAAIgAAACUAAACAAAUABgAAACgAAAAmAAAAJwAAAEEABgApAAAAKgAAACAAAAAV'
    'AAAAIQAAAD4AAwAqAAAAKAAAAPkAAgAcAAAA+AACABwAAAD9AAEAOAABAA==')
COUNT = 1 << 20  # values in the buffer
MUL = 2654435761 & 0xFFFFFFFF  # v[i] = i * MUL + 7, modulo 2^32
REPEAT = 50

# VkPhysicalDeviceFeatures, in order.
FEATURES = (
    'robustBufferAccess fullDrawIndexUint32 imageCubeArray independentBlend geometryShader '
    'tessellationShader sampleRateShading dualSrcBlend logicOp multiDrawIndirect '
    'drawIndirectFirstInstance depthClamp depthBiasClamp fillModeNonSolid depthBounds wideLines '
    'largePoints alphaToOne multiViewport samplerAnisotropy textureCompressionETC2 '
    'textureCompressionASTC_LDR textureCompressionBC occlusionQueryPrecise pipelineStatisticsQuery '
    'vertexPipelineStoresAndAtomics fragmentStoresAndAtomics shaderTessellationAndGeometryPointSize '
    'shaderImageGatherExtended shaderStorageImageExtendedFormats shaderStorageImageMultisample '
    'shaderStorageImageReadWithoutFormat shaderStorageImageWriteWithoutFormat '
    'shaderUniformBufferArrayDynamicIndexing shaderSampledImageArrayDynamicIndexing '
    'shaderStorageBufferArrayDynamicIndexing shaderStorageImageArrayDynamicIndexing '
    'shaderClipDistance shaderCullDistance shaderFloat64 shaderInt64 shaderInt16 '
    'shaderResourceResidency shaderResourceMinLod sparseBinding sparseResidencyBuffer '
    'sparseResidencyImage2D sparseResidencyImage3D sparseResidency2Samples sparseResidency4Samples '
    'sparseResidency8Samples sparseResidency16Samples sparseResidencyAliased variableMultisampleRate '
    'inheritedQueries').split()
SHOWN_FEATURES = ('geometryShader', 'tessellationShader', 'shaderFloat64', 'shaderInt64',
                  'shaderInt16', 'multiViewport', 'samplerAnisotropy', 'textureCompressionBC',
                  'textureCompressionETC2', 'textureCompressionASTC_LDR', 'logicOp', 'dualSrcBlend',
                  'depthClamp', 'fillModeNonSolid', 'wideLines', 'sparseBinding')
# Extensions emulators and video players commonly ask for; reported present or absent.
SHOWN_EXTENSIONS = ('VK_KHR_swapchain', 'VK_KHR_timeline_semaphore', 'VK_KHR_maintenance3',
                    'VK_KHR_shader_float16_int8', 'VK_KHR_8bit_storage', 'VK_KHR_16bit_storage',
                    'VK_KHR_draw_indirect_count', 'VK_KHR_buffer_device_address',
                    'VK_KHR_driver_properties', 'VK_EXT_descriptor_indexing',
                    'VK_EXT_robustness2', 'VK_EXT_extended_dynamic_state',
                    'VK_EXT_custom_border_color', 'VK_EXT_transform_feedback',
                    'VK_EXT_vertex_attribute_divisor', 'VK_EXT_index_type_uint8',
                    'VK_EXT_shader_viewport_index_layer', 'VK_KHR_external_memory_fd')


class Failed(Exception):
    pass


def say(key, value):
    print(f'{key}={value}', flush=True)


def version(value):
    return f'{value >> 22 & 0x7F}.{value >> 12 & 0x3FF}.{value & 0xFFF}'


def nvidia_version(value):  # NVIDIA's driverVersion packing
    return f'{value >> 22 & 0x3FF}.{value >> 14 & 0xFF}.{value >> 6 & 0xFF}'


class S(ctypes.Structure):
    pass


def struct(name, *fields):
    return type(name, (ctypes.Structure,), {'_fields_': list(fields)})


Head = (('sType', c_int32), ('pNext', c_void_p))
ApplicationInfo = struct('ApplicationInfo', *Head, ('pApplicationName', c_char_p),
                         ('applicationVersion', c_uint32), ('pEngineName', c_char_p),
                         ('engineVersion', c_uint32), ('apiVersion', c_uint32))
InstanceCreateInfo = struct('InstanceCreateInfo', *Head, ('flags', c_uint32),
                            ('pApplicationInfo', POINTER(ApplicationInfo)),
                            ('enabledLayerCount', c_uint32), ('ppEnabledLayerNames', c_void_p),
                            ('enabledExtensionCount', c_uint32), ('ppEnabledExtensionNames', c_void_p))
QueueFamilyProperties = struct('QueueFamilyProperties', ('queueFlags', c_uint32),
                               ('queueCount', c_uint32), ('timestampValidBits', c_uint32),
                               ('granularity', c_uint32 * 3))
ExtensionProperties = struct('ExtensionProperties', ('extensionName', ctypes.c_char * 256),
                             ('specVersion', c_uint32))
MemoryType = struct('MemoryType', ('propertyFlags', c_uint32), ('heapIndex', c_uint32))
MemoryHeap = struct('MemoryHeap', ('size', c_uint64), ('flags', c_uint32))
MemoryProperties = struct('MemoryProperties', ('memoryTypeCount', c_uint32),
                          ('memoryTypes', MemoryType * 32), ('memoryHeapCount', c_uint32),
                          ('memoryHeaps', MemoryHeap * 16))
DeviceQueueCreateInfo = struct('DeviceQueueCreateInfo', *Head, ('flags', c_uint32),
                               ('queueFamilyIndex', c_uint32), ('queueCount', c_uint32),
                               ('pQueuePriorities', POINTER(c_float)))
DeviceCreateInfo = struct('DeviceCreateInfo', *Head, ('flags', c_uint32),
                          ('queueCreateInfoCount', c_uint32),
                          ('pQueueCreateInfos', POINTER(DeviceQueueCreateInfo)),
                          ('enabledLayerCount', c_uint32), ('ppEnabledLayerNames', c_void_p),
                          ('enabledExtensionCount', c_uint32), ('ppEnabledExtensionNames', c_void_p),
                          ('pEnabledFeatures', c_void_p))
BufferCreateInfo = struct('BufferCreateInfo', *Head, ('flags', c_uint32), ('size', c_uint64),
                          ('usage', c_uint32), ('sharingMode', c_int32),
                          ('queueFamilyIndexCount', c_uint32), ('pQueueFamilyIndices', c_void_p))
MemoryRequirements = struct('MemoryRequirements', ('size', c_uint64), ('alignment', c_uint64),
                            ('memoryTypeBits', c_uint32))
MemoryAllocateInfo = struct('MemoryAllocateInfo', *Head, ('allocationSize', c_uint64),
                            ('memoryTypeIndex', c_uint32))
ShaderModuleCreateInfo = struct('ShaderModuleCreateInfo', *Head, ('flags', c_uint32),
                                ('codeSize', c_size_t), ('pCode', c_void_p))
DescriptorSetLayoutBinding = struct('DescriptorSetLayoutBinding', ('binding', c_uint32),
                                    ('descriptorType', c_int32), ('descriptorCount', c_uint32),
                                    ('stageFlags', c_uint32), ('pImmutableSamplers', c_void_p))
DescriptorSetLayoutCreateInfo = struct('DescriptorSetLayoutCreateInfo', *Head, ('flags', c_uint32),
                                       ('bindingCount', c_uint32),
                                       ('pBindings', POINTER(DescriptorSetLayoutBinding)))
PushConstantRange = struct('PushConstantRange', ('stageFlags', c_uint32), ('offset', c_uint32),
                           ('size', c_uint32))
PipelineLayoutCreateInfo = struct('PipelineLayoutCreateInfo', *Head, ('flags', c_uint32),
                                  ('setLayoutCount', c_uint32), ('pSetLayouts', POINTER(Handle)),
                                  ('pushConstantRangeCount', c_uint32),
                                  ('pPushConstantRanges', POINTER(PushConstantRange)))
ShaderStageCreateInfo = struct('ShaderStageCreateInfo', *Head, ('flags', c_uint32),
                               ('stage', c_uint32), ('module', Handle), ('pName', c_char_p),
                               ('pSpecializationInfo', c_void_p))
ComputePipelineCreateInfo = struct('ComputePipelineCreateInfo', *Head, ('flags', c_uint32),
                                   ('stage', ShaderStageCreateInfo), ('layout', Handle),
                                   ('basePipelineHandle', Handle), ('basePipelineIndex', c_int32))
DescriptorPoolSize = struct('DescriptorPoolSize', ('type', c_int32), ('descriptorCount', c_uint32))
DescriptorPoolCreateInfo = struct('DescriptorPoolCreateInfo', *Head, ('flags', c_uint32),
                                  ('maxSets', c_uint32), ('poolSizeCount', c_uint32),
                                  ('pPoolSizes', POINTER(DescriptorPoolSize)))
DescriptorSetAllocateInfo = struct('DescriptorSetAllocateInfo', *Head, ('descriptorPool', Handle),
                                   ('descriptorSetCount', c_uint32), ('pSetLayouts', POINTER(Handle)))
DescriptorBufferInfo = struct('DescriptorBufferInfo', ('buffer', Handle), ('offset', c_uint64),
                              ('range', c_uint64))
WriteDescriptorSet = struct('WriteDescriptorSet', *Head, ('dstSet', Handle), ('dstBinding', c_uint32),
                            ('dstArrayElement', c_uint32), ('descriptorCount', c_uint32),
                            ('descriptorType', c_int32), ('pImageInfo', c_void_p),
                            ('pBufferInfo', POINTER(DescriptorBufferInfo)),
                            ('pTexelBufferView', c_void_p))
CommandPoolCreateInfo = struct('CommandPoolCreateInfo', *Head, ('flags', c_uint32),
                               ('queueFamilyIndex', c_uint32))
CommandBufferAllocateInfo = struct('CommandBufferAllocateInfo', *Head, ('commandPool', Handle),
                                   ('level', c_int32), ('commandBufferCount', c_uint32))
CommandBufferBeginInfo = struct('CommandBufferBeginInfo', *Head, ('flags', c_uint32),
                                ('pInheritanceInfo', c_void_p))
MemoryBarrier = struct('MemoryBarrier', *Head, ('srcAccessMask', c_uint32), ('dstAccessMask', c_uint32))
FenceCreateInfo = struct('FenceCreateInfo', *Head, ('flags', c_uint32))
SubmitInfo = struct('SubmitInfo', *Head, ('waitSemaphoreCount', c_uint32), ('pWaitSemaphores', c_void_p),
                    ('pWaitDstStageMask', c_void_p), ('commandBufferCount', c_uint32),
                    ('pCommandBuffers', POINTER(c_void_p)), ('signalSemaphoreCount', c_uint32),
                    ('pSignalSemaphores', c_void_p))


class Vulkan:
    """The loader's exported Vulkan 1.0 commands (and vkEnumerateInstanceVersion)."""

    def __init__(self, path):
        self.lib = ctypes.CDLL(path)

    def __getattr__(self, name):
        function = getattr(self.lib, name)
        function.restype = c_int32
        setattr(self, name, function)
        return function

    def call(self, name, *args):
        result = getattr(self, name)(*args)
        if result not in (VK_SUCCESS, VK_INCOMPLETE):
            raise Failed(f'{name} returned {result}')
        return result

    def void(self, name, *args):
        function = getattr(self.lib, name)
        function.restype = None
        function(*args)


def enumerate_list(vk, name, item, *args, void=False):
    """The two-call count-then-fill pattern; void for commands that return nothing,
    whose return register holds garbage (on arm64, a nonzero one)."""
    run = vk.void if void else vk.call
    count = c_uint32()
    run(name, *args, ctypes.byref(count), None)
    items = (item * count.value)()
    if count.value:
        run(name, *args, ctypes.byref(count), items)
    return list(items)[:count.value]


def physical_devices(vk, instance, any_vendor):
    chosen = None
    for index, device in enumerate(enumerate_list(vk, 'vkEnumeratePhysicalDevices', c_void_p, instance)):
        raw = ctypes.create_string_buffer(4096)  # VkPhysicalDeviceProperties is 824 bytes on 64-bit
        vk.void('vkGetPhysicalDeviceProperties', c_void_p(device), raw)
        api, driver, vendor, device_id, kind = array.array('I', raw.raw[:20])
        name = raw.raw[20:276].split(b'\0', 1)[0].decode(errors='replace')
        driver_text = nvidia_version(driver) if vendor == NVIDIA else hex(driver)
        say(f'VK_DEVICE_{index}', f'{name} vendor=0x{vendor:04x} device=0x{device_id:x} '
            f'type={DEVICE_TYPES.get(kind, kind)} api={version(api)} driver={driver_text}')
        if chosen is None and (vendor == NVIDIA or any_vendor):
            chosen = (c_void_p(device), name, api, driver, vendor)
    if chosen is None:
        say('VK_PHYSICAL_DEVICE', 'FAIL no NVIDIA device')
        raise Failed
    return chosen


def describe(vk, physical):
    features = (c_uint32 * len(FEATURES))()
    vk.void('vkGetPhysicalDeviceFeatures', physical, features)
    on = {name for name, value in zip(FEATURES, features) if value}
    say('VK_FEATURES', f'{len(on)} of {len(FEATURES)}')
    say('VK_FEATURES_SHOWN', ' '.join(f'{name}={"yes" if name in on else "no"}' for name in SHOWN_FEATURES))
    say('VK_FEATURES_ALL', ' '.join(name for name in FEATURES if name in on))
    names = [e.extensionName.decode() for e in
             enumerate_list(vk, 'vkEnumerateDeviceExtensionProperties', ExtensionProperties, physical, None)]
    say('VK_DEVICE_EXTENSIONS', len(names))
    say('VK_DEVICE_EXTENSIONS_SHOWN', ' '.join(f'{name}={"yes" if name in names else "no"}'
                                               for name in SHOWN_EXTENSIONS))
    say('VK_DEVICE_EXTENSIONS_ALL', ' '.join(sorted(names)))
    memory = MemoryProperties()
    vk.void('vkGetPhysicalDeviceMemoryProperties', physical, ctypes.byref(memory))
    heaps = [f'{memory.memoryHeaps[i].size / 2**30:.2f}GiB' for i in range(memory.memoryHeapCount)]
    say('VK_MEMORY_HEAPS', ' '.join(heaps))
    wanted = MEMORY_HOST_VISIBLE | MEMORY_HOST_COHERENT
    host_types = [i for i in range(memory.memoryTypeCount)
                  if memory.memoryTypes[i].propertyFlags & wanted == wanted]
    families = enumerate_list(vk, 'vkGetPhysicalDeviceQueueFamilyProperties', QueueFamilyProperties,
                              physical, void=True)
    say('VK_QUEUE_FAMILIES', ' '.join(f'{i}:flags=0x{f.queueFlags:x},count={f.queueCount}'
                                      for i, f in enumerate(families)))
    compute = [i for i, f in enumerate(families) if f.queueFlags & QUEUE_COMPUTE]
    if not compute:
        say('VK_COMPUTE_QUEUE', 'FAIL none')
        raise Failed
    return compute[0], host_types


def compute_test(vk, physical, family, host_types):
    priority = c_float(1.0)
    queue_info = DeviceQueueCreateInfo(sType=2, queueFamilyIndex=family, queueCount=1,
                                       pQueuePriorities=ctypes.pointer(priority))
    device = c_void_p()
    vk.call('vkCreateDevice', physical, ctypes.byref(DeviceCreateInfo(
        sType=3, queueCreateInfoCount=1, pQueueCreateInfos=ctypes.pointer(queue_info))),
        None, ctypes.byref(device))
    say('VK_DEVICE', 'PASS')
    queue = c_void_p()
    vk.void('vkGetDeviceQueue', device, family, 0, ctypes.byref(queue))

    size = COUNT * 4
    buffer = Handle()
    vk.call('vkCreateBuffer', device, ctypes.byref(BufferCreateInfo(sType=12, size=size, usage=BUFFER_STORAGE)),
            None, ctypes.byref(buffer))
    needs = MemoryRequirements()
    vk.void('vkGetBufferMemoryRequirements', device, buffer, ctypes.byref(needs))
    usable = [i for i in host_types if needs.memoryTypeBits >> i & 1]
    if not usable:
        say('VK_MEMORY', 'FAIL no host-visible, coherent memory type for a storage buffer')
        raise Failed
    memory = Handle()
    vk.call('vkAllocateMemory', device, ctypes.byref(MemoryAllocateInfo(
        sType=5, allocationSize=needs.size, memoryTypeIndex=usable[0])), None, ctypes.byref(memory))
    vk.call('vkBindBufferMemory', device, buffer, memory, c_uint64(0))
    mapped = c_void_p()
    vk.call('vkMapMemory', device, memory, c_uint64(0), c_uint64(size), 0, ctypes.byref(mapped))
    ctypes.memset(mapped, 0, size)
    say('VK_MEMORY', f'PASS {size} bytes, type {usable[0]}')

    code = ctypes.create_string_buffer(FILL_SPV, len(FILL_SPV))
    module = Handle()
    vk.call('vkCreateShaderModule', device, ctypes.byref(ShaderModuleCreateInfo(
        sType=16, codeSize=len(FILL_SPV), pCode=ctypes.cast(code, c_void_p))), None, ctypes.byref(module))
    binding = DescriptorSetLayoutBinding(binding=0, descriptorType=DESCRIPTOR_STORAGE_BUFFER,
                                         descriptorCount=1, stageFlags=STAGE_COMPUTE)
    set_layout = Handle()
    vk.call('vkCreateDescriptorSetLayout', device, ctypes.byref(DescriptorSetLayoutCreateInfo(
        sType=32, bindingCount=1, pBindings=ctypes.pointer(binding))), None, ctypes.byref(set_layout))
    push = PushConstantRange(stageFlags=STAGE_COMPUTE, offset=0, size=8)
    layout = Handle()
    vk.call('vkCreatePipelineLayout', device, ctypes.byref(PipelineLayoutCreateInfo(
        sType=30, setLayoutCount=1, pSetLayouts=ctypes.pointer(set_layout), pushConstantRangeCount=1,
        pPushConstantRanges=ctypes.pointer(push))), None, ctypes.byref(layout))
    pipeline = Handle()
    stage = ShaderStageCreateInfo(sType=18, stage=STAGE_COMPUTE, module=module, pName=b'main')
    vk.call('vkCreateComputePipelines', device, Handle(0), 1, ctypes.byref(ComputePipelineCreateInfo(
        sType=29, stage=stage, layout=layout, basePipelineIndex=-1)), None, ctypes.byref(pipeline))
    say('VK_PIPELINE', 'PASS (the driver compiled the SPIR-V compute shader)')

    pool_size = DescriptorPoolSize(type=DESCRIPTOR_STORAGE_BUFFER, descriptorCount=1)
    pool = Handle()
    vk.call('vkCreateDescriptorPool', device, ctypes.byref(DescriptorPoolCreateInfo(
        sType=33, maxSets=1, poolSizeCount=1, pPoolSizes=ctypes.pointer(pool_size))), None, ctypes.byref(pool))
    descriptor_set = Handle()
    vk.call('vkAllocateDescriptorSets', device, ctypes.byref(DescriptorSetAllocateInfo(
        sType=34, descriptorPool=pool, descriptorSetCount=1, pSetLayouts=ctypes.pointer(set_layout))),
        ctypes.byref(descriptor_set))
    buffer_info = DescriptorBufferInfo(buffer=buffer, offset=0, range=size)
    vk.void('vkUpdateDescriptorSets', device, 1, ctypes.byref(WriteDescriptorSet(
        sType=35, dstSet=descriptor_set, dstBinding=0, descriptorCount=1,
        descriptorType=DESCRIPTOR_STORAGE_BUFFER, pBufferInfo=ctypes.pointer(buffer_info))), 0, None)

    command_pool = Handle()
    vk.call('vkCreateCommandPool', device, ctypes.byref(CommandPoolCreateInfo(
        sType=39, flags=0x2, queueFamilyIndex=family)), None, ctypes.byref(command_pool))
    fence = Handle()
    vk.call('vkCreateFence', device, ctypes.byref(FenceCreateInfo(sType=8)), None, ctypes.byref(fence))
    constants = (c_uint32 * 2)(COUNT, MUL)
    groups = (COUNT + 63) // 64

    def run(times):
        command = c_void_p()
        vk.call('vkAllocateCommandBuffers', device, ctypes.byref(CommandBufferAllocateInfo(
            sType=40, commandPool=command_pool, level=0, commandBufferCount=1)), ctypes.byref(command))
        vk.call('vkBeginCommandBuffer', command, ctypes.byref(CommandBufferBeginInfo(sType=42, flags=1)))
        vk.void('vkCmdBindPipeline', command, PIPELINE_BIND_COMPUTE, pipeline)
        vk.void('vkCmdBindDescriptorSets', command, PIPELINE_BIND_COMPUTE, layout, 0, 1,
                ctypes.byref(descriptor_set), 0, None)
        vk.void('vkCmdPushConstants', command, layout, STAGE_COMPUTE, 0, 8, constants)
        between = MemoryBarrier(sType=46, srcAccessMask=ACCESS_SHADER_WRITE, dstAccessMask=ACCESS_SHADER_WRITE)
        for index in range(times):
            if index:
                vk.void('vkCmdPipelineBarrier', command, STAGE_COMPUTE_SHADER, STAGE_COMPUTE_SHADER, 0,
                        1, ctypes.byref(between), 0, None, 0, None)
            vk.void('vkCmdDispatch', command, groups, 1, 1)
        to_host = MemoryBarrier(sType=46, srcAccessMask=ACCESS_SHADER_WRITE, dstAccessMask=ACCESS_HOST_READ)
        vk.void('vkCmdPipelineBarrier', command, STAGE_COMPUTE_SHADER, STAGE_HOST, 0,
                1, ctypes.byref(to_host), 0, None, 0, None)
        vk.call('vkEndCommandBuffer', command)
        commands = (c_void_p * 1)(command)
        vk.call('vkResetFences', device, 1, ctypes.byref(fence))
        start = time.perf_counter()
        vk.call('vkQueueSubmit', queue, 1, ctypes.byref(SubmitInfo(
            sType=4, commandBufferCount=1, pCommandBuffers=commands)), fence)
        result = vk.vkWaitForFences(device, 1, ctypes.byref(fence), 1, c_uint64(20 * 10**9))
        seconds = time.perf_counter() - start
        if result != VK_SUCCESS:
            raise Failed(f'vkWaitForFences returned {result}')
        vk.void('vkFreeCommandBuffers', device, command_pool, 1, commands)
        return seconds

    seconds = run(1)
    values = array.array('I', ctypes.string_at(mapped, size))
    bad = [i for i in range(COUNT) if values[i] != (i * MUL + 7) & 0xFFFFFFFF]
    if bad:
        first = bad[0]
        say('VK_COMPUTE', f'FAIL {len(bad)} of {COUNT} values wrong; v[{first}]={values[first]}, '
            f'expected {(first * MUL + 7) & 0xFFFFFFFF}')
        raise Failed
    say('VK_COMPUTE', f'PASS {COUNT} values exact ({seconds * 1000:.1f} ms with the first submission)')
    ctypes.memset(mapped, 0, size)
    seconds = run(REPEAT)
    values = array.array('I', ctypes.string_at(mapped, size))
    exact = all(values[i] == (i * MUL + 7) & 0xFFFFFFFF for i in range(0, COUNT, 4093))
    say('VK_COMPUTE_RATE', f'{"PASS" if exact else "FAIL"} {REPEAT} dispatches in {seconds:.4f} s, '
        f'{REPEAT * size / seconds / 1e9:.2f} GB/s written')
    if not exact:
        raise Failed

    vk.void('vkDestroyFence', device, fence, None)
    vk.void('vkDestroyCommandPool', device, command_pool, None)
    vk.void('vkDestroyDescriptorPool', device, pool, None)
    vk.void('vkDestroyPipeline', device, pipeline, None)
    vk.void('vkDestroyPipelineLayout', device, layout, None)
    vk.void('vkDestroyDescriptorSetLayout', device, set_layout, None)
    vk.void('vkDestroyShaderModule', device, module, None)
    vk.void('vkUnmapMemory', device, memory)
    vk.void('vkFreeMemory', device, memory, None)
    vk.void('vkDestroyBuffer', device, buffer, None)
    vk.void('vkDestroyDevice', device, None)


def mapped_libraries(root):
    seen = []
    with open('/proc/self/maps') as maps:
        for line in maps:
            fields = line.split(None, 5)
            path = fields[5].strip() if len(fields) == 6 else ''
            base = os.path.basename(path)
            if path.startswith('/') and path not in seen and (
                    base.startswith(('libnv', 'libcuda', 'libvulkan', 'libGL')) or '_nvidia' in base):
                seen.append(path)
    outside = []
    for path in seen:
        say('LIB', path)
        base = os.path.basename(path)
        nvidia = base.startswith(('libnv', 'libcuda')) or '_nvidia' in base
        if root and nvidia and not os.path.realpath(path).startswith(os.path.realpath(root) + os.sep):
            outside.append(path)
    if root:
        say('LIB_MIX', 'PASS' if not outside else 'FAIL ' + ' '.join(outside))
    return not outside


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--vulkan', default='libvulkan.so.1', help="the Vulkan loader's path or soname")
    parser.add_argument('--lib-root', help='folder every NVIDIA library must come from')
    parser.add_argument('--any-vendor', action='store_true', help='use the first device of any vendor')
    args = parser.parse_args()
    for name in ('VK_DRIVER_FILES', 'VK_ICD_FILENAMES', 'DISPLAY', 'WAYLAND_DISPLAY'):
        say(f'ENV_{name}', os.environ.get(name, ''))
    ok = False
    try:
        vk = Vulkan(args.vulkan)
        loader = c_uint32(0)
        if hasattr(vk.lib, 'vkEnumerateInstanceVersion'):
            vk.call('vkEnumerateInstanceVersion', ctypes.byref(loader))
        say('VK_LOADER', f'PASS {version(loader.value) if loader.value else "1.0"}')
        app = ApplicationInfo(sType=0, pApplicationName=b'vk_probe', pEngineName=b'none',
                              apiVersion=VK_API_1_1)
        instance = c_void_p()
        vk.call('vkCreateInstance', ctypes.byref(InstanceCreateInfo(
            sType=1, pApplicationInfo=ctypes.pointer(app))), None, ctypes.byref(instance))
        say('VK_INSTANCE', 'PASS')
        physical, name, api, driver, vendor = physical_devices(vk, instance, args.any_vendor)
        say('VK_PHYSICAL_DEVICE', f'PASS {name} api={version(api)}')
        family, host_types = describe(vk, physical)
        compute_test(vk, physical, family, host_types)
        vk.void('vkDestroyInstance', instance, None)
        ok = True
    except OSError as error:  # a library or symbol that does not load
        say('LOAD_ERROR', str(error).replace('\n', ' '))
    except AttributeError as error:
        say('SYMBOL_ERROR', str(error))
    except Failed as error:
        if str(error):
            say('VK_ERROR', str(error))
    ok = mapped_libraries(args.lib_root) and ok
    say('PROBE', 'PASS' if ok else 'FAIL')
    sys.stdout.flush()
    os._exit(0 if ok else 1)  # skip library destructors, which may not expect ctypes' order


if __name__ == '__main__':
    main()
