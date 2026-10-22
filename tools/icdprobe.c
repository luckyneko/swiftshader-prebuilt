// Load a Vulkan ICD the way the Vulkan loader does, and prove it is the driver the archive claims
// to hold: a CPU device reporting Vulkan 1.3 or later, with the features archimedes cannot run
// without, that creates a device with those features enabled.
//
// It talks to the library directly rather than through a loader, so what it tests is the file in
// hand and nothing a system install could substitute for it.
//
// Usage: icdprobe <library>
//
// Prints "key: value" lines for the manifest, and exits non-zero, saying why, on the first
// requirement that fails.

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VK_NO_PROTOTYPES
#include <vulkan/vk_icd.h>
#include <vulkan/vulkan.h>

#if defined(_WIN32)
#	include <windows.h>
#	include <tlhelp32.h>
#else
#	include <dlfcn.h>
#	if defined(__APPLE__)
#		include <mach/mach.h>
#	else
#		include <dirent.h>
#	endif
#endif

static void fail(const char* format, ...)
{
	va_list args;
	va_start(args, format);
	fprintf(stderr, "icdprobe: FAIL: ");
	vfprintf(stderr, format, args);
	fprintf(stderr, "\n");
	va_end(args);
	exit(1);
}

static void* openLibrary(const char* path)
{
#if defined(_WIN32)
	return (void*)LoadLibraryA(path);
#else
	return dlopen(path, RTLD_NOW | RTLD_LOCAL);
#endif
}

static const char* openError(void)
{
#if defined(_WIN32)
	static char message[32];
	snprintf(message, sizeof(message), "error %lu", (unsigned long)GetLastError());
	return message;
#else
	return dlerror();
#endif
}

// An EXPORTED symbol, which is how a loader finds the entry points: being linked in is not enough.
static void* exported(void* library, const char* name)
{
#if defined(_WIN32)
	return (void*)GetProcAddress((HMODULE)library, name);
#else
	return dlsym(library, name);
#endif
}

// Threads in this process, so the probe can report how many the driver starts. SwiftShader's
// worker pool is the one thing about it a host process has to budget for, and the thing
// SWIFTSHADER_THREAD_COUNT controls.
static long threadCount(void)
{
#if defined(_WIN32)
	HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
	if(snapshot == INVALID_HANDLE_VALUE)
		return -1;
	THREADENTRY32 entry;
	entry.dwSize = sizeof(entry);
	long count = 0;
	DWORD self = GetCurrentProcessId();
	if(Thread32First(snapshot, &entry))
	{
		do
		{
			if(entry.th32OwnerProcessID == self)
				++count;
		} while(Thread32Next(snapshot, &entry));
	}
	CloseHandle(snapshot);
	return count;
#elif defined(__APPLE__)
	thread_act_array_t threads;
	mach_msg_type_number_t count;
	if(task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS)
		return -1;
	for(mach_msg_type_number_t i = 0; i < count; ++i)
		mach_port_deallocate(mach_task_self(), threads[i]);
	vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(threads[0]));
	return (long)count;
#else
	DIR* tasks = opendir("/proc/self/task");
	if(!tasks)
		return -1;
	long count = 0;
	struct dirent* entry;
	while((entry = readdir(tasks)) != NULL)
	{
		if(entry->d_name[0] != '.')
			++count;
	}
	closedir(tasks);
	return count;
#endif
}

static const char* deviceTypeName(VkPhysicalDeviceType type)
{
	switch(type)
	{
	case VK_PHYSICAL_DEVICE_TYPE_OTHER: return "other";
	case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: return "integrated-gpu";
	case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU: return "discrete-gpu";
	case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU: return "virtual-gpu";
	case VK_PHYSICAL_DEVICE_TYPE_CPU: return "cpu";
	default: return "unknown";
	}
}

#define LOAD(instance, name) \
	PFN_##name name = (PFN_##name)getInstanceProcAddr(instance, #name); \
	if(!name) \
		fail("vk_icdGetInstanceProcAddr returned no %s", #name);

int main(int argc, char** argv)
{
	if(argc != 2)
	{
		fprintf(stderr, "usage: icdprobe <library>\n");
		return 2;
	}

	void* library = openLibrary(argv[1]);
	if(!library)
		fail("cannot load %s: %s", argv[1], openError());

	// The loader's half of the interface, in the loader's order: negotiate first, then resolve
	// everything through vk_icdGetInstanceProcAddr.
	PFN_vk_icdNegotiateLoaderICDInterfaceVersion negotiate =
	    (PFN_vk_icdNegotiateLoaderICDInterfaceVersion)exported(library, "vk_icdNegotiateLoaderICDInterfaceVersion");
	PFN_vk_icdGetInstanceProcAddr getInstanceProcAddr =
	    (PFN_vk_icdGetInstanceProcAddr)exported(library, "vk_icdGetInstanceProcAddr");
	if(!negotiate)
		fail("vk_icdNegotiateLoaderICDInterfaceVersion is not exported");
	if(!getInstanceProcAddr)
		fail("vk_icdGetInstanceProcAddr is not exported");

	uint32_t interfaceVersion = CURRENT_LOADER_ICD_INTERFACE_VERSION;
	if(negotiate(&interfaceVersion) != VK_SUCCESS)
		fail("vk_icdNegotiateLoaderICDInterfaceVersion refused version %u", CURRENT_LOADER_ICD_INTERFACE_VERSION);
	printf("icd interface: %u\n", interfaceVersion);

	LOAD(NULL, vkCreateInstance);
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO };
	app.pApplicationName = "icdprobe";
	app.apiVersion = VK_API_VERSION_1_3;
	VkInstanceCreateInfo instanceInfo = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
	instanceInfo.pApplicationInfo = &app;
	VkInstance instance = VK_NULL_HANDLE;
	VkResult result = vkCreateInstance(&instanceInfo, NULL, &instance);
	if(result != VK_SUCCESS)
		fail("vkCreateInstance returned %d", (int)result);

	LOAD(instance, vkEnumeratePhysicalDevices);
	LOAD(instance, vkGetPhysicalDeviceProperties2);
	LOAD(instance, vkGetPhysicalDeviceFeatures2);
	LOAD(instance, vkGetPhysicalDeviceQueueFamilyProperties);
	LOAD(instance, vkCreateDevice);
	LOAD(instance, vkDestroyDevice);
	LOAD(instance, vkDestroyInstance);

	uint32_t count = 0;
	vkEnumeratePhysicalDevices(instance, &count, NULL);
	if(count == 0)
		fail("the driver reports no physical device");
	VkPhysicalDevice* devices = (VkPhysicalDevice*)calloc(count, sizeof(VkPhysicalDevice));
	vkEnumeratePhysicalDevices(instance, &count, devices);
	VkPhysicalDevice device = devices[0];
	free(devices);

	VkPhysicalDeviceDriverProperties driver = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES };
	VkPhysicalDeviceProperties2 properties = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &driver };
	vkGetPhysicalDeviceProperties2(device, &properties);
	uint32_t api = properties.properties.apiVersion;
	printf("device: %s\n", properties.properties.deviceName);
	printf("device type: %s\n", deviceTypeName(properties.properties.deviceType));
	printf("api version: %u.%u.%u\n", VK_API_VERSION_MAJOR(api), VK_API_VERSION_MINOR(api), VK_API_VERSION_PATCH(api));
	printf("driver: %s%s%s\n", driver.driverName, driver.driverInfo[0] ? " " : "", driver.driverInfo);
	printf("driver version: 0x%08x\n", properties.properties.driverVersion);
	printf("conformance version: %u.%u.%u.%u\n", driver.conformanceVersion.major, driver.conformanceVersion.minor,
	       driver.conformanceVersion.subminor, driver.conformanceVersion.patch);

	if(properties.properties.deviceType != VK_PHYSICAL_DEVICE_TYPE_CPU)
		fail("device type is %s, not cpu", deviceTypeName(properties.properties.deviceType));
	if(api < VK_API_VERSION_1_3)
		fail("api version %u.%u is below 1.3", VK_API_VERSION_MAJOR(api), VK_API_VERSION_MINOR(api));

	// What archimedes requires of every device it will use.
	VkPhysicalDeviceVulkan13Features features13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES };
	VkPhysicalDeviceFeatures2 features = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &features13 };
	vkGetPhysicalDeviceFeatures2(device, &features);
	printf("synchronization2: %s\n", features13.synchronization2 ? "yes" : "no");
	printf("dynamicRendering: %s\n", features13.dynamicRendering ? "yes" : "no");
	if(!features13.synchronization2 || !features13.dynamicRendering)
		fail("synchronization2 and dynamicRendering are both required");

	uint32_t familyCount = 0;
	vkGetPhysicalDeviceQueueFamilyProperties(device, &familyCount, NULL);
	VkQueueFamilyProperties* families = (VkQueueFamilyProperties*)calloc(familyCount, sizeof(VkQueueFamilyProperties));
	vkGetPhysicalDeviceQueueFamilyProperties(device, &familyCount, families);
	const VkQueueFlags wanted = VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT;
	uint32_t family = familyCount;
	for(uint32_t i = 0; i < familyCount && family == familyCount; ++i)
	{
		if((families[i].queueFlags & wanted) == wanted)
			family = i;
	}
	free(families);
	if(family == familyCount)
		fail("no queue family supports both graphics and compute");

	// Creating the device is where the driver starts its worker pool, and where a feature it
	// advertised but cannot actually enable would be refused.
	float priority = 1.0f;
	VkDeviceQueueCreateInfo queueInfo = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
	queueInfo.queueFamilyIndex = family;
	queueInfo.queueCount = 1;
	queueInfo.pQueuePriorities = &priority;
	VkPhysicalDeviceVulkan13Features enable13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES };
	enable13.synchronization2 = VK_TRUE;
	enable13.dynamicRendering = VK_TRUE;
	VkDeviceCreateInfo deviceInfo = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &enable13 };
	deviceInfo.queueCreateInfoCount = 1;
	deviceInfo.pQueueCreateInfos = &queueInfo;
	VkDevice logical = VK_NULL_HANDLE;
	// Counted around this one call, not from process start: on Windows the OS loader runs its own
	// worker threads during LoadLibrary, which would blur the count.
	long threadsBefore = threadCount();
	result = vkCreateDevice(device, &deviceInfo, NULL, &logical);
	if(result != VK_SUCCESS)
		fail("vkCreateDevice with synchronization2 + dynamicRendering returned %d", (int)result);
	long threadsAfter = threadCount();
	if(threadsBefore >= 0 && threadsAfter >= 0)
		printf("threads started by vkCreateDevice: %ld\n", threadsAfter - threadsBefore);

	vkDestroyDevice(logical, NULL);
	vkDestroyInstance(instance, NULL);
	printf("result: ok\n");
	return 0;
}
