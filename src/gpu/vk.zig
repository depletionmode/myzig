//! The Vulkan API, the part the renderer uses, declared by hand: the loader
//! (libvulkan.so.1, vulkan-1.dll) is opened at run time, so building needs
//! neither the SDK nor its headers and an app that draws otherwise never
//! maps the driver. Layouts follow vulkan_core.h; every struct's size was
//! checked against the headers' sizeof.

const std = @import("std");
const sys = @import("../sys.zig");
const builtin = @import("builtin");

pub const CC: std.builtin.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;

pub const Instance = *opaque {};
pub const PhysicalDevice = *opaque {};
pub const Device = *opaque {};
pub const Queue = *opaque {};
pub const CommandBuffer = *opaque {};
pub const Handle = u64; // every non-dispatchable handle; 0 is none
pub const SurfaceKHR = Handle;
pub const SwapchainKHR = Handle;
pub const Image = Handle;
pub const ImageView = Handle;
pub const Buffer = Handle;
pub const DeviceMemory = Handle;
pub const RenderPass = Handle;
pub const Framebuffer = Handle;
pub const ShaderModule = Handle;
pub const Pipeline = Handle;
pub const PipelineLayout = Handle;
pub const DescriptorSetLayout = Handle;
pub const DescriptorPool = Handle;
pub const DescriptorSet = Handle;
pub const Sampler = Handle;
pub const CommandPool = Handle;
pub const Semaphore = Handle;
pub const Fence = Handle;

pub const Result = i32;
pub const SUCCESS: Result = 0;
pub const TIMEOUT: Result = 2;
pub const SUBOPTIMAL_KHR: Result = 1000001003;
pub const ERROR_OUT_OF_DATE_KHR: Result = -1000001004;

pub const Bool32 = u32;
pub const Flags = u32;
pub const DeviceSize = u64;

pub const StructureType = enum(i32) {
    application_info = 0,
    instance_create_info = 1,
    device_queue_create_info = 2,
    device_create_info = 3,
    submit_info = 4,
    memory_allocate_info = 5,
    fence_create_info = 8,
    semaphore_create_info = 9,
    buffer_create_info = 12,
    image_create_info = 14,
    image_view_create_info = 15,
    shader_module_create_info = 16,
    pipeline_shader_stage_create_info = 18,
    pipeline_vertex_input_state_create_info = 19,
    pipeline_input_assembly_state_create_info = 20,
    pipeline_viewport_state_create_info = 22,
    pipeline_rasterization_state_create_info = 23,
    pipeline_multisample_state_create_info = 24,
    pipeline_color_blend_state_create_info = 26,
    pipeline_dynamic_state_create_info = 27,
    graphics_pipeline_create_info = 28,
    pipeline_layout_create_info = 30,
    sampler_create_info = 31,
    descriptor_set_layout_create_info = 32,
    descriptor_pool_create_info = 33,
    descriptor_set_allocate_info = 34,
    write_descriptor_set = 35,
    framebuffer_create_info = 37,
    render_pass_create_info = 38,
    command_pool_create_info = 39,
    command_buffer_allocate_info = 40,
    command_buffer_begin_info = 42,
    render_pass_begin_info = 43,
    image_memory_barrier = 45,
    swapchain_create_info_khr = 1000001000,
    present_info_khr = 1000001001,
    xlib_surface_create_info_khr = 1000004000,
    wayland_surface_create_info_khr = 1000006000,
    win32_surface_create_info_khr = 1000009000,
    metal_surface_create_info_ext = 1000217000,
};

pub const Extent2D = extern struct { width: u32, height: u32 };
pub const Extent3D = extern struct { width: u32, height: u32, depth: u32 };
pub const Offset2D = extern struct { x: i32, y: i32 };
pub const Offset3D = extern struct { x: i32, y: i32, z: i32 };
pub const Rect2D = extern struct { offset: Offset2D, extent: Extent2D };
pub const Viewport = extern struct { x: f32, y: f32, width: f32, height: f32, min_depth: f32, max_depth: f32 };

pub const ApplicationInfo = extern struct {
    s_type: StructureType = .application_info,
    p_next: ?*const anyopaque = null,
    p_application_name: ?[*:0]const u8 = null,
    application_version: u32 = 0,
    p_engine_name: ?[*:0]const u8 = null,
    engine_version: u32 = 0,
    api_version: u32,
};

pub const InstanceCreateInfo = extern struct {
    s_type: StructureType = .instance_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    p_application_info: ?*const ApplicationInfo = null,
    enabled_layer_count: u32 = 0,
    pp_enabled_layer_names: ?[*]const [*:0]const u8 = null,
    enabled_extension_count: u32 = 0,
    pp_enabled_extension_names: ?[*]const [*:0]const u8 = null,
};

pub const XlibSurfaceCreateInfoKHR = extern struct {
    s_type: StructureType = .xlib_surface_create_info_khr,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    dpy: *anyopaque,
    window: c_ulong,
};

pub const WaylandSurfaceCreateInfoKHR = extern struct {
    s_type: StructureType = .wayland_surface_create_info_khr,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    display: *anyopaque,
    surface: *anyopaque,
};

pub const Win32SurfaceCreateInfoKHR = extern struct {
    s_type: StructureType = .win32_surface_create_info_khr,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    hinstance: *anyopaque,
    hwnd: *anyopaque,
};

pub const MetalSurfaceCreateInfoEXT = extern struct {
    s_type: StructureType = .metal_surface_create_info_ext,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    layer: *anyopaque,
};

/// INSTANCE_CREATE_ENUMERATE_PORTABILITY lists drivers that implement
/// Vulkan over another API (MoltenVK over Metal).
pub const INSTANCE_CREATE_ENUMERATE_PORTABILITY: Flags = 1;

pub const PhysicalDeviceType = enum(i32) { other = 0, integrated_gpu = 1, discrete_gpu = 2, virtual_gpu = 3, cpu = 4, _ };

/// PhysicalDeviceProperties is the head of VkPhysicalDeviceProperties,
/// with room for the limits after it (824 bytes in the headers).
pub const PhysicalDeviceProperties = extern struct {
    api_version: u32,
    driver_version: u32,
    vendor_id: u32,
    device_id: u32,
    device_type: PhysicalDeviceType,
    device_name: [256]u8,
    pipeline_cache_uuid: [16]u8,
    rest: [1024]u8 align(8),
};

pub const QueueFamilyProperties = extern struct {
    queue_flags: Flags,
    queue_count: u32,
    timestamp_valid_bits: u32,
    min_image_transfer_granularity: Extent3D,
};

pub const MemoryType = extern struct { property_flags: Flags, heap_index: u32 };
pub const MemoryHeap = extern struct { size: DeviceSize, flags: Flags };
pub const PhysicalDeviceMemoryProperties = extern struct {
    memory_type_count: u32,
    memory_types: [32]MemoryType,
    memory_heap_count: u32,
    memory_heaps: [16]MemoryHeap,
};

pub const DeviceQueueCreateInfo = extern struct {
    s_type: StructureType = .device_queue_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    queue_family_index: u32,
    queue_count: u32,
    p_queue_priorities: [*]const f32,
};

pub const DeviceCreateInfo = extern struct {
    s_type: StructureType = .device_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    queue_create_info_count: u32,
    p_queue_create_infos: [*]const DeviceQueueCreateInfo,
    enabled_layer_count: u32 = 0,
    pp_enabled_layer_names: ?[*]const [*:0]const u8 = null,
    enabled_extension_count: u32 = 0,
    pp_enabled_extension_names: ?[*]const [*:0]const u8 = null,
    p_enabled_features: ?*const anyopaque = null,
};

pub const SurfaceCapabilitiesKHR = extern struct {
    min_image_count: u32,
    max_image_count: u32,
    current_extent: Extent2D,
    min_image_extent: Extent2D,
    max_image_extent: Extent2D,
    max_image_array_layers: u32,
    supported_transforms: Flags,
    current_transform: Flags,
    supported_composite_alpha: Flags,
    supported_usage_flags: Flags,
};

pub const SurfaceFormatKHR = extern struct { format: Format, color_space: i32 };

pub const Format = enum(i32) {
    undefined = 0,
    r8_unorm = 9,
    r8g8b8a8_unorm = 37,
    b8g8r8a8_unorm = 44,
    r32g32b32a32_sfloat = 109,
    _,
};

pub const PresentMode = enum(i32) { immediate = 0, mailbox = 1, fifo = 2, fifo_relaxed = 3, _ };

pub const SwapchainCreateInfoKHR = extern struct {
    s_type: StructureType = .swapchain_create_info_khr,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    surface: SurfaceKHR,
    min_image_count: u32,
    image_format: Format,
    image_color_space: i32,
    image_extent: Extent2D,
    image_array_layers: u32 = 1,
    image_usage: Flags,
    image_sharing_mode: i32 = 0,
    queue_family_index_count: u32 = 0,
    p_queue_family_indices: ?[*]const u32 = null,
    pre_transform: Flags,
    composite_alpha: Flags,
    present_mode: PresentMode,
    clipped: Bool32 = 1,
    old_swapchain: SwapchainKHR = 0,
};

pub const ComponentMapping = extern struct { r: i32 = 0, g: i32 = 0, b: i32 = 0, a: i32 = 0 };
pub const ImageSubresourceRange = extern struct {
    aspect_mask: Flags = IMAGE_ASPECT_COLOR,
    base_mip_level: u32 = 0,
    level_count: u32 = 1,
    base_array_layer: u32 = 0,
    layer_count: u32 = 1,
};
pub const ImageSubresourceLayers = extern struct {
    aspect_mask: Flags = IMAGE_ASPECT_COLOR,
    mip_level: u32 = 0,
    base_array_layer: u32 = 0,
    layer_count: u32 = 1,
};

pub const ImageViewCreateInfo = extern struct {
    s_type: StructureType = .image_view_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    image: Image,
    view_type: i32 = 1, // 2D
    format: Format,
    components: ComponentMapping = .{},
    subresource_range: ImageSubresourceRange = .{},
};

pub const ImageLayout = enum(i32) {
    undefined = 0,
    general = 1,
    color_attachment_optimal = 2,
    shader_read_only_optimal = 5,
    transfer_src_optimal = 6,
    transfer_dst_optimal = 7,
    present_src_khr = 1000001002,
};

pub const AttachmentDescription = extern struct {
    flags: Flags = 0,
    format: Format,
    samples: Flags = 1,
    load_op: i32,
    store_op: i32,
    stencil_load_op: i32 = 2,
    stencil_store_op: i32 = 1,
    initial_layout: ImageLayout,
    final_layout: ImageLayout,
};

pub const AttachmentReference = extern struct { attachment: u32, layout: ImageLayout };

pub const SubpassDescription = extern struct {
    flags: Flags = 0,
    pipeline_bind_point: i32 = 0,
    input_attachment_count: u32 = 0,
    p_input_attachments: ?[*]const AttachmentReference = null,
    color_attachment_count: u32,
    p_color_attachments: [*]const AttachmentReference,
    p_resolve_attachments: ?[*]const AttachmentReference = null,
    p_depth_stencil_attachment: ?*const AttachmentReference = null,
    preserve_attachment_count: u32 = 0,
    p_preserve_attachments: ?[*]const u32 = null,
};

pub const SubpassDependency = extern struct {
    src_subpass: u32,
    dst_subpass: u32,
    src_stage_mask: Flags,
    dst_stage_mask: Flags,
    src_access_mask: Flags,
    dst_access_mask: Flags,
    dependency_flags: Flags = 0,
};

pub const RenderPassCreateInfo = extern struct {
    s_type: StructureType = .render_pass_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    attachment_count: u32,
    p_attachments: [*]const AttachmentDescription,
    subpass_count: u32,
    p_subpasses: [*]const SubpassDescription,
    dependency_count: u32,
    p_dependencies: [*]const SubpassDependency,
};

pub const FramebufferCreateInfo = extern struct {
    s_type: StructureType = .framebuffer_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    render_pass: RenderPass,
    attachment_count: u32 = 1,
    p_attachments: [*]const ImageView,
    width: u32,
    height: u32,
    layers: u32 = 1,
};

pub const ShaderModuleCreateInfo = extern struct {
    s_type: StructureType = .shader_module_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    code_size: usize,
    p_code: [*]const u32,
};

pub const DescriptorSetLayoutBinding = extern struct {
    binding: u32,
    descriptor_type: i32,
    descriptor_count: u32,
    stage_flags: Flags,
    p_immutable_samplers: ?[*]const Sampler = null,
};

pub const DescriptorSetLayoutCreateInfo = extern struct {
    s_type: StructureType = .descriptor_set_layout_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    binding_count: u32,
    p_bindings: [*]const DescriptorSetLayoutBinding,
};

pub const PushConstantRange = extern struct { stage_flags: Flags, offset: u32, size: u32 };

pub const PipelineLayoutCreateInfo = extern struct {
    s_type: StructureType = .pipeline_layout_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    set_layout_count: u32,
    p_set_layouts: [*]const DescriptorSetLayout,
    push_constant_range_count: u32,
    p_push_constant_ranges: [*]const PushConstantRange,
};

pub const PipelineShaderStageCreateInfo = extern struct {
    s_type: StructureType = .pipeline_shader_stage_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    stage: Flags,
    module: ShaderModule,
    p_name: [*:0]const u8 = "main",
    p_specialization_info: ?*const anyopaque = null,
};

pub const VertexInputBindingDescription = extern struct { binding: u32, stride: u32, input_rate: i32 };
pub const VertexInputAttributeDescription = extern struct { location: u32, binding: u32, format: Format, offset: u32 };

pub const PipelineVertexInputStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_vertex_input_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    vertex_binding_description_count: u32,
    p_vertex_binding_descriptions: [*]const VertexInputBindingDescription,
    vertex_attribute_description_count: u32,
    p_vertex_attribute_descriptions: [*]const VertexInputAttributeDescription,
};

pub const PipelineInputAssemblyStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_input_assembly_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    topology: i32,
    primitive_restart_enable: Bool32 = 0,
};

pub const PipelineViewportStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_viewport_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    viewport_count: u32 = 1,
    p_viewports: ?[*]const Viewport = null,
    scissor_count: u32 = 1,
    p_scissors: ?[*]const Rect2D = null,
};

pub const PipelineRasterizationStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_rasterization_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    depth_clamp_enable: Bool32 = 0,
    rasterizer_discard_enable: Bool32 = 0,
    polygon_mode: i32 = 0,
    cull_mode: Flags = 0,
    front_face: i32 = 0,
    depth_bias_enable: Bool32 = 0,
    depth_bias_constant_factor: f32 = 0,
    depth_bias_clamp: f32 = 0,
    depth_bias_slope_factor: f32 = 0,
    line_width: f32 = 1,
};

pub const PipelineMultisampleStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_multisample_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    rasterization_samples: Flags = 1,
    sample_shading_enable: Bool32 = 0,
    min_sample_shading: f32 = 0,
    p_sample_mask: ?*const u32 = null,
    alpha_to_coverage_enable: Bool32 = 0,
    alpha_to_one_enable: Bool32 = 0,
};

pub const PipelineColorBlendAttachmentState = extern struct {
    blend_enable: Bool32,
    src_color_blend_factor: i32,
    dst_color_blend_factor: i32,
    color_blend_op: i32 = 0,
    src_alpha_blend_factor: i32,
    dst_alpha_blend_factor: i32,
    alpha_blend_op: i32 = 0,
    color_write_mask: Flags = 0xf,
};

pub const PipelineColorBlendStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_color_blend_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    logic_op_enable: Bool32 = 0,
    logic_op: i32 = 0,
    attachment_count: u32,
    p_attachments: [*]const PipelineColorBlendAttachmentState,
    blend_constants: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const PipelineDynamicStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_dynamic_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    dynamic_state_count: u32,
    p_dynamic_states: [*]const i32,
};

pub const GraphicsPipelineCreateInfo = extern struct {
    s_type: StructureType = .graphics_pipeline_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    stage_count: u32,
    p_stages: [*]const PipelineShaderStageCreateInfo,
    p_vertex_input_state: *const PipelineVertexInputStateCreateInfo,
    p_input_assembly_state: *const PipelineInputAssemblyStateCreateInfo,
    p_tessellation_state: ?*const anyopaque = null,
    p_viewport_state: *const PipelineViewportStateCreateInfo,
    p_rasterization_state: *const PipelineRasterizationStateCreateInfo,
    p_multisample_state: *const PipelineMultisampleStateCreateInfo,
    p_depth_stencil_state: ?*const anyopaque = null,
    p_color_blend_state: *const PipelineColorBlendStateCreateInfo,
    p_dynamic_state: *const PipelineDynamicStateCreateInfo,
    layout: PipelineLayout,
    render_pass: RenderPass,
    subpass: u32 = 0,
    base_pipeline_handle: Pipeline = 0,
    base_pipeline_index: i32 = -1,
};

pub const BufferCreateInfo = extern struct {
    s_type: StructureType = .buffer_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    size: DeviceSize,
    usage: Flags,
    sharing_mode: i32 = 0,
    queue_family_index_count: u32 = 0,
    p_queue_family_indices: ?[*]const u32 = null,
};

pub const MemoryRequirements = extern struct { size: DeviceSize, alignment: DeviceSize, memory_type_bits: u32 };

pub const MemoryAllocateInfo = extern struct {
    s_type: StructureType = .memory_allocate_info,
    p_next: ?*const anyopaque = null,
    allocation_size: DeviceSize,
    memory_type_index: u32,
};

pub const ImageCreateInfo = extern struct {
    s_type: StructureType = .image_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    image_type: i32 = 1, // 2D
    format: Format,
    extent: Extent3D,
    mip_levels: u32 = 1,
    array_layers: u32 = 1,
    samples: Flags = 1,
    tiling: i32 = 0, // optimal
    usage: Flags,
    sharing_mode: i32 = 0,
    queue_family_index_count: u32 = 0,
    p_queue_family_indices: ?[*]const u32 = null,
    initial_layout: ImageLayout = .undefined,
};

pub const SamplerCreateInfo = extern struct {
    s_type: StructureType = .sampler_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    mag_filter: i32 = 0,
    min_filter: i32 = 0,
    mipmap_mode: i32 = 0,
    address_mode_u: i32 = 2,
    address_mode_v: i32 = 2,
    address_mode_w: i32 = 2,
    mip_lod_bias: f32 = 0,
    anisotropy_enable: Bool32 = 0,
    max_anisotropy: f32 = 1,
    compare_enable: Bool32 = 0,
    compare_op: i32 = 0,
    min_lod: f32 = 0,
    max_lod: f32 = 0,
    border_color: i32 = 0,
    unnormalized_coordinates: Bool32 = 0,
};

pub const DescriptorPoolSize = extern struct { type: i32, descriptor_count: u32 };

pub const DescriptorPoolCreateInfo = extern struct {
    s_type: StructureType = .descriptor_pool_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    max_sets: u32,
    pool_size_count: u32,
    p_pool_sizes: [*]const DescriptorPoolSize,
};

pub const DescriptorSetAllocateInfo = extern struct {
    s_type: StructureType = .descriptor_set_allocate_info,
    p_next: ?*const anyopaque = null,
    descriptor_pool: DescriptorPool,
    descriptor_set_count: u32,
    p_set_layouts: [*]const DescriptorSetLayout,
};

pub const DescriptorImageInfo = extern struct { sampler: Sampler, image_view: ImageView, image_layout: ImageLayout };

pub const WriteDescriptorSet = extern struct {
    s_type: StructureType = .write_descriptor_set,
    p_next: ?*const anyopaque = null,
    dst_set: DescriptorSet,
    dst_binding: u32,
    dst_array_element: u32 = 0,
    descriptor_count: u32,
    descriptor_type: i32,
    p_image_info: ?[*]const DescriptorImageInfo = null,
    p_buffer_info: ?*const anyopaque = null,
    p_texel_buffer_view: ?*const anyopaque = null,
};

pub const CommandPoolCreateInfo = extern struct {
    s_type: StructureType = .command_pool_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    queue_family_index: u32,
};

pub const CommandBufferAllocateInfo = extern struct {
    s_type: StructureType = .command_buffer_allocate_info,
    p_next: ?*const anyopaque = null,
    command_pool: CommandPool,
    level: i32 = 0,
    command_buffer_count: u32,
};

pub const CommandBufferBeginInfo = extern struct {
    s_type: StructureType = .command_buffer_begin_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
    p_inheritance_info: ?*const anyopaque = null,
};

pub const SemaphoreCreateInfo = extern struct {
    s_type: StructureType = .semaphore_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
};

pub const FenceCreateInfo = extern struct {
    s_type: StructureType = .fence_create_info,
    p_next: ?*const anyopaque = null,
    flags: Flags = 0,
};

pub const ClearValue = extern struct { color: [4]f32 };

pub const RenderPassBeginInfo = extern struct {
    s_type: StructureType = .render_pass_begin_info,
    p_next: ?*const anyopaque = null,
    render_pass: RenderPass,
    framebuffer: Framebuffer,
    render_area: Rect2D,
    clear_value_count: u32,
    p_clear_values: [*]const ClearValue,
};

pub const ImageMemoryBarrier = extern struct {
    s_type: StructureType = .image_memory_barrier,
    p_next: ?*const anyopaque = null,
    src_access_mask: Flags,
    dst_access_mask: Flags,
    old_layout: ImageLayout,
    new_layout: ImageLayout,
    src_queue_family_index: u32 = QUEUE_FAMILY_IGNORED,
    dst_queue_family_index: u32 = QUEUE_FAMILY_IGNORED,
    image: Image,
    subresource_range: ImageSubresourceRange = .{},
};

pub const BufferImageCopy = extern struct {
    buffer_offset: DeviceSize,
    buffer_row_length: u32 = 0,
    buffer_image_height: u32 = 0,
    image_subresource: ImageSubresourceLayers = .{},
    image_offset: Offset3D,
    image_extent: Extent3D,
};

pub const ClearColorValue = extern struct { float32: [4]f32 };

pub const SubmitInfo = extern struct {
    s_type: StructureType = .submit_info,
    p_next: ?*const anyopaque = null,
    wait_semaphore_count: u32 = 0,
    p_wait_semaphores: ?[*]const Semaphore = null,
    p_wait_dst_stage_mask: ?[*]const Flags = null,
    command_buffer_count: u32,
    p_command_buffers: [*]const CommandBuffer,
    signal_semaphore_count: u32 = 0,
    p_signal_semaphores: ?[*]const Semaphore = null,
};

pub const PresentInfoKHR = extern struct {
    s_type: StructureType = .present_info_khr,
    p_next: ?*const anyopaque = null,
    wait_semaphore_count: u32,
    p_wait_semaphores: [*]const Semaphore,
    swapchain_count: u32,
    p_swapchains: [*]const SwapchainKHR,
    p_image_indices: [*]const u32,
    p_results: ?[*]Result = null,
};

pub const QUEUE_FAMILY_IGNORED: u32 = ~@as(u32, 0);
pub const SUBPASS_EXTERNAL: u32 = ~@as(u32, 0);
pub const IMAGE_ASPECT_COLOR: Flags = 1;
pub const QUEUE_GRAPHICS: Flags = 1;
pub const IMAGE_USAGE_TRANSFER_SRC: Flags = 0x1;
pub const IMAGE_USAGE_TRANSFER_DST: Flags = 0x2;
pub const IMAGE_USAGE_SAMPLED: Flags = 0x4;
pub const IMAGE_USAGE_COLOR_ATTACHMENT: Flags = 0x10;
pub const BUFFER_USAGE_TRANSFER_SRC: Flags = 0x1;
pub const BUFFER_USAGE_TRANSFER_DST: Flags = 0x2;
pub const BUFFER_USAGE_VERTEX: Flags = 0x80;
pub const MEMORY_DEVICE_LOCAL: Flags = 1;
pub const MEMORY_HOST_VISIBLE: Flags = 2;
pub const MEMORY_HOST_COHERENT: Flags = 4;
pub const STAGE_TOP_OF_PIPE: Flags = 0x1;
pub const STAGE_FRAGMENT_SHADER: Flags = 0x80;
pub const STAGE_COLOR_ATTACHMENT_OUTPUT: Flags = 0x400;
pub const STAGE_TRANSFER: Flags = 0x1000;
pub const STAGE_BOTTOM_OF_PIPE: Flags = 0x2000;
pub const STAGE_HOST: Flags = 0x4000;
pub const ACCESS_SHADER_READ: Flags = 0x20;
pub const ACCESS_COLOR_ATTACHMENT_WRITE: Flags = 0x100;
pub const ACCESS_TRANSFER_READ: Flags = 0x800;
pub const ACCESS_TRANSFER_WRITE: Flags = 0x1000;
pub const ACCESS_HOST_READ: Flags = 0x2000;
pub const ACCESS_MEMORY_READ: Flags = 0x8000;
pub const SHADER_STAGE_VERTEX: Flags = 0x1;
pub const SHADER_STAGE_FRAGMENT: Flags = 0x10;
pub const DESCRIPTOR_COMBINED_IMAGE_SAMPLER: i32 = 1;
pub const COMPOSITE_ALPHA_OPAQUE: Flags = 1;
pub const ATTACHMENT_LOAD_CLEAR: i32 = 1;
pub const ATTACHMENT_STORE_STORE: i32 = 0;
pub const TOPOLOGY_TRIANGLE_STRIP: i32 = 4;
pub const INPUT_RATE_INSTANCE: i32 = 1;
pub const BLEND_ONE: i32 = 1;
pub const BLEND_ONE_MINUS_SRC_ALPHA: i32 = 7;
pub const DYNAMIC_VIEWPORT: i32 = 0;
pub const DYNAMIC_SCISSOR: i32 = 1;
pub const COMMAND_POOL_RESET_BUFFER: Flags = 2;
pub const COMMAND_BUFFER_ONE_TIME: Flags = 1;
pub const FENCE_SIGNALED: Flags = 1;

/// Base holds the functions there are before an instance.
pub const Base = struct {
    CreateInstance: *const fn (*const InstanceCreateInfo, ?*const anyopaque, *Instance) callconv(CC) Result,
};

/// InstanceFns holds the functions of an instance; the surface ones are
/// there only where the platform's extension is.
pub const InstanceFns = struct {
    DestroyInstance: *const fn (Instance, ?*const anyopaque) callconv(CC) void,
    EnumeratePhysicalDevices: *const fn (Instance, *u32, ?[*]PhysicalDevice) callconv(CC) Result,
    GetPhysicalDeviceProperties: *const fn (PhysicalDevice, *PhysicalDeviceProperties) callconv(CC) void,
    GetPhysicalDeviceQueueFamilyProperties: *const fn (PhysicalDevice, *u32, ?[*]QueueFamilyProperties) callconv(CC) void,
    GetPhysicalDeviceMemoryProperties: *const fn (PhysicalDevice, *PhysicalDeviceMemoryProperties) callconv(CC) void,
    CreateDevice: *const fn (PhysicalDevice, *const DeviceCreateInfo, ?*const anyopaque, *Device) callconv(CC) Result,
    GetDeviceProcAddr: *const fn (Device, [*:0]const u8) callconv(CC) ?*const anyopaque,
    GetPhysicalDeviceSurfaceSupportKHR: ?*const fn (PhysicalDevice, u32, SurfaceKHR, *Bool32) callconv(CC) Result,
    GetPhysicalDeviceSurfaceCapabilitiesKHR: ?*const fn (PhysicalDevice, SurfaceKHR, *SurfaceCapabilitiesKHR) callconv(CC) Result,
    GetPhysicalDeviceSurfaceFormatsKHR: ?*const fn (PhysicalDevice, SurfaceKHR, *u32, ?[*]SurfaceFormatKHR) callconv(CC) Result,
    GetPhysicalDeviceSurfacePresentModesKHR: ?*const fn (PhysicalDevice, SurfaceKHR, *u32, ?[*]PresentMode) callconv(CC) Result,
    DestroySurfaceKHR: ?*const fn (Instance, SurfaceKHR, ?*const anyopaque) callconv(CC) void,
    CreateXlibSurfaceKHR: ?*const fn (Instance, *const XlibSurfaceCreateInfoKHR, ?*const anyopaque, *SurfaceKHR) callconv(CC) Result,
    CreateWaylandSurfaceKHR: ?*const fn (Instance, *const WaylandSurfaceCreateInfoKHR, ?*const anyopaque, *SurfaceKHR) callconv(CC) Result,
    CreateWin32SurfaceKHR: ?*const fn (Instance, *const Win32SurfaceCreateInfoKHR, ?*const anyopaque, *SurfaceKHR) callconv(CC) Result,
    CreateMetalSurfaceEXT: ?*const fn (Instance, *const MetalSurfaceCreateInfoEXT, ?*const anyopaque, *SurfaceKHR) callconv(CC) Result,
};

/// DeviceFns holds the functions of a device; the swapchain ones are there
/// only when drawing to a window.
pub const DeviceFns = struct {
    DestroyDevice: *const fn (Device, ?*const anyopaque) callconv(CC) void,
    GetDeviceQueue: *const fn (Device, u32, u32, *Queue) callconv(CC) void,
    DeviceWaitIdle: *const fn (Device) callconv(CC) Result,
    CreateSwapchainKHR: ?*const fn (Device, *const SwapchainCreateInfoKHR, ?*const anyopaque, *SwapchainKHR) callconv(CC) Result,
    DestroySwapchainKHR: ?*const fn (Device, SwapchainKHR, ?*const anyopaque) callconv(CC) void,
    GetSwapchainImagesKHR: ?*const fn (Device, SwapchainKHR, *u32, ?[*]Image) callconv(CC) Result,
    AcquireNextImageKHR: ?*const fn (Device, SwapchainKHR, u64, Semaphore, Fence, *u32) callconv(CC) Result,
    QueuePresentKHR: ?*const fn (Queue, *const PresentInfoKHR) callconv(CC) Result,
    CreateImageView: *const fn (Device, *const ImageViewCreateInfo, ?*const anyopaque, *ImageView) callconv(CC) Result,
    DestroyImageView: *const fn (Device, ImageView, ?*const anyopaque) callconv(CC) void,
    CreateRenderPass: *const fn (Device, *const RenderPassCreateInfo, ?*const anyopaque, *RenderPass) callconv(CC) Result,
    DestroyRenderPass: *const fn (Device, RenderPass, ?*const anyopaque) callconv(CC) void,
    CreateFramebuffer: *const fn (Device, *const FramebufferCreateInfo, ?*const anyopaque, *Framebuffer) callconv(CC) Result,
    DestroyFramebuffer: *const fn (Device, Framebuffer, ?*const anyopaque) callconv(CC) void,
    CreateShaderModule: *const fn (Device, *const ShaderModuleCreateInfo, ?*const anyopaque, *ShaderModule) callconv(CC) Result,
    DestroyShaderModule: *const fn (Device, ShaderModule, ?*const anyopaque) callconv(CC) void,
    CreateDescriptorSetLayout: *const fn (Device, *const DescriptorSetLayoutCreateInfo, ?*const anyopaque, *DescriptorSetLayout) callconv(CC) Result,
    DestroyDescriptorSetLayout: *const fn (Device, DescriptorSetLayout, ?*const anyopaque) callconv(CC) void,
    CreatePipelineLayout: *const fn (Device, *const PipelineLayoutCreateInfo, ?*const anyopaque, *PipelineLayout) callconv(CC) Result,
    DestroyPipelineLayout: *const fn (Device, PipelineLayout, ?*const anyopaque) callconv(CC) void,
    CreateGraphicsPipelines: *const fn (Device, Handle, u32, [*]const GraphicsPipelineCreateInfo, ?*const anyopaque, [*]Pipeline) callconv(CC) Result,
    DestroyPipeline: *const fn (Device, Pipeline, ?*const anyopaque) callconv(CC) void,
    CreateBuffer: *const fn (Device, *const BufferCreateInfo, ?*const anyopaque, *Buffer) callconv(CC) Result,
    DestroyBuffer: *const fn (Device, Buffer, ?*const anyopaque) callconv(CC) void,
    GetBufferMemoryRequirements: *const fn (Device, Buffer, *MemoryRequirements) callconv(CC) void,
    CreateImage: *const fn (Device, *const ImageCreateInfo, ?*const anyopaque, *Image) callconv(CC) Result,
    DestroyImage: *const fn (Device, Image, ?*const anyopaque) callconv(CC) void,
    GetImageMemoryRequirements: *const fn (Device, Image, *MemoryRequirements) callconv(CC) void,
    AllocateMemory: *const fn (Device, *const MemoryAllocateInfo, ?*const anyopaque, *DeviceMemory) callconv(CC) Result,
    FreeMemory: *const fn (Device, DeviceMemory, ?*const anyopaque) callconv(CC) void,
    BindBufferMemory: *const fn (Device, Buffer, DeviceMemory, DeviceSize) callconv(CC) Result,
    BindImageMemory: *const fn (Device, Image, DeviceMemory, DeviceSize) callconv(CC) Result,
    MapMemory: *const fn (Device, DeviceMemory, DeviceSize, DeviceSize, Flags, *?*anyopaque) callconv(CC) Result,
    CreateSampler: *const fn (Device, *const SamplerCreateInfo, ?*const anyopaque, *Sampler) callconv(CC) Result,
    DestroySampler: *const fn (Device, Sampler, ?*const anyopaque) callconv(CC) void,
    CreateDescriptorPool: *const fn (Device, *const DescriptorPoolCreateInfo, ?*const anyopaque, *DescriptorPool) callconv(CC) Result,
    DestroyDescriptorPool: *const fn (Device, DescriptorPool, ?*const anyopaque) callconv(CC) void,
    AllocateDescriptorSets: *const fn (Device, *const DescriptorSetAllocateInfo, [*]DescriptorSet) callconv(CC) Result,
    UpdateDescriptorSets: *const fn (Device, u32, [*]const WriteDescriptorSet, u32, ?*const anyopaque) callconv(CC) void,
    CreateCommandPool: *const fn (Device, *const CommandPoolCreateInfo, ?*const anyopaque, *CommandPool) callconv(CC) Result,
    DestroyCommandPool: *const fn (Device, CommandPool, ?*const anyopaque) callconv(CC) void,
    AllocateCommandBuffers: *const fn (Device, *const CommandBufferAllocateInfo, [*]CommandBuffer) callconv(CC) Result,
    CreateSemaphore: *const fn (Device, *const SemaphoreCreateInfo, ?*const anyopaque, *Semaphore) callconv(CC) Result,
    DestroySemaphore: *const fn (Device, Semaphore, ?*const anyopaque) callconv(CC) void,
    CreateFence: *const fn (Device, *const FenceCreateInfo, ?*const anyopaque, *Fence) callconv(CC) Result,
    DestroyFence: *const fn (Device, Fence, ?*const anyopaque) callconv(CC) void,
    WaitForFences: *const fn (Device, u32, [*]const Fence, Bool32, u64) callconv(CC) Result,
    ResetFences: *const fn (Device, u32, [*]const Fence) callconv(CC) Result,
    QueueSubmit: *const fn (Queue, u32, [*]const SubmitInfo, Fence) callconv(CC) Result,
    BeginCommandBuffer: *const fn (CommandBuffer, *const CommandBufferBeginInfo) callconv(CC) Result,
    EndCommandBuffer: *const fn (CommandBuffer) callconv(CC) Result,
    ResetCommandBuffer: *const fn (CommandBuffer, Flags) callconv(CC) Result,
    CmdBeginRenderPass: *const fn (CommandBuffer, *const RenderPassBeginInfo, i32) callconv(CC) void,
    CmdEndRenderPass: *const fn (CommandBuffer) callconv(CC) void,
    CmdBindPipeline: *const fn (CommandBuffer, i32, Pipeline) callconv(CC) void,
    CmdBindDescriptorSets: *const fn (CommandBuffer, i32, PipelineLayout, u32, u32, [*]const DescriptorSet, u32, ?[*]const u32) callconv(CC) void,
    CmdBindVertexBuffers: *const fn (CommandBuffer, u32, u32, [*]const Buffer, [*]const DeviceSize) callconv(CC) void,
    CmdPushConstants: *const fn (CommandBuffer, PipelineLayout, Flags, u32, u32, *const anyopaque) callconv(CC) void,
    CmdSetViewport: *const fn (CommandBuffer, u32, u32, [*]const Viewport) callconv(CC) void,
    CmdSetScissor: *const fn (CommandBuffer, u32, u32, [*]const Rect2D) callconv(CC) void,
    CmdDraw: *const fn (CommandBuffer, u32, u32, u32, u32) callconv(CC) void,
    CmdPipelineBarrier: *const fn (CommandBuffer, Flags, Flags, Flags, u32, ?*const anyopaque, u32, ?*const anyopaque, u32, [*]const ImageMemoryBarrier) callconv(CC) void,
    CmdCopyBufferToImage: *const fn (CommandBuffer, Buffer, Image, ImageLayout, u32, [*]const BufferImageCopy) callconv(CC) void,
    CmdCopyImageToBuffer: *const fn (CommandBuffer, Image, ImageLayout, Buffer, u32, [*]const BufferImageCopy) callconv(CC) void,
    CmdClearColorImage: *const fn (CommandBuffer, Image, ImageLayout, *const ClearColorValue, u32, [*]const ImageSubresourceRange) callconv(CC) void,
};

/// load fills a table of T by name ("vk" ++ field) with proc; a required
/// function that is missing is an error, an optional one is null.
pub fn load(comptime T: type, ctx: anytype, comptime proc: anytype) !T {
    var t: T = undefined;
    const ti = @typeInfo(T).@"struct";
    inline for (ti.field_names, ti.field_types) |name, ftype| {
        const p = proc(ctx, "vk" ++ name);
        if (@typeInfo(ftype) == .optional) {
            @field(t, name) = if (p) |q| @ptrCast(@alignCast(q)) else null;
        } else {
            @field(t, name) = @ptrCast(@alignCast(p orelse {
                sys.log(.err, "myzig: Vulkan has no vk{s}", .{name});
                return error.MissingFunction;
            }));
        }
    }
    return t;
}

pub fn check(r: Result) !void {
    if (r != SUCCESS) {
        sys.log(.err, "myzig: Vulkan error {d}", .{r});
        return error.Vulkan;
    }
}

pub fn makeVersion(major: u32, minor: u32, patch: u32) u32 {
    return (major << 22) | (minor << 12) | patch;
}
