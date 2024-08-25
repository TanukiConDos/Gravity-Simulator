#include "imGUIWindow.h"

namespace Engine
{
	namespace Graphic
	{
		ImGUIWindow::ImGUIWindow(Application::Window& window, GPU& gpu,SwapChain& swapChain, Pipeline& pipeline,VkInstance instance,float* frameTime, float* tickTime)
		{
            _stateMachine->_frameTime = frameTime;
            _stateMachine->_tickTime = tickTime;

            VkDescriptorPoolSize pool_sizes[] = { { VK_DESCRIPTOR_TYPE_SAMPLER, 1000 },
                { VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1000 },
                { VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 1000 },
                { VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1000 },
                { VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 1000 },
                { VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, 1000 },
                { VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1000 },
                { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1000 },
                { VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, 1000 },
                { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, 1000 },
                { VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT, 1000 } };

            VkDescriptorPoolCreateInfo pool_info = {};
            pool_info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
            pool_info.flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
            pool_info.maxSets = 1000;
            pool_info.poolSizeCount = (uint32_t)std::size(pool_sizes);
            pool_info.pPoolSizes = pool_sizes;

            
            if (vkCreateDescriptorPool(gpu.getDevice(), &pool_info, nullptr, &_imguiPool) != VK_SUCCESS) {
                throw std::runtime_error("failed to create descriptor pool!");
            }
            IMGUI_CHECKVERSION();
            ImGui::CreateContext();

            ImGui::StyleColorsDark();

            ImGui_ImplGlfw_InitForVulkan(window.getWindow(), true);
            ImGui_ImplVulkan_InitInfo init_info = {};
            init_info.Instance = instance;
            init_info.PhysicalDevice = gpu.getPhysicalDevice();
            init_info.Device = gpu.getDevice();
            init_info.QueueFamily = 0;
            init_info.Queue = gpu.getGraphicsQueue();
            init_info.PipelineCache = VK_NULL_HANDLE;
            init_info.DescriptorPool = _imguiPool;
            init_info.RenderPass = swapChain.getRenderPass();
            init_info.Subpass = 0;
            init_info.MinImageCount = 3;
            init_info.ImageCount = 3;
            init_info.MSAASamples = VK_SAMPLE_COUNT_1_BIT;
            init_info.Allocator = VK_NULL_HANDLE;
            init_info.CheckVkResultFn = VK_NULL_HANDLE;
            ImGui_ImplVulkan_Init(&init_info);
		}
        ImGUIWindow::~ImGUIWindow()
        {
            ImGui_ImplVulkan_Shutdown();
            ImGui_ImplGlfw_Shutdown();
            ImGui::DestroyContext();
        }

        void ImGUIWindow::startFrame()
        {
            ImGui_ImplVulkan_NewFrame();
            ImGui_ImplGlfw_NewFrame();
            ImGui::NewFrame();
            _stateMachine->frame();
            ImGui::Render();
        }

        void ImGUIWindow::draw(VkCommandBuffer commandBuffer)
        {
            ImGui_ImplVulkan_RenderDrawData(ImGui::GetDrawData(), commandBuffer);
        }
	}
}