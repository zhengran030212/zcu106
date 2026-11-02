// Platform driver for the ZCU106 blit engine (ID 0x47505531).
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/io.h>
#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/uaccess.h>

#define GPU_ID 0x47505531u

struct gpu_regs {
	u32 dst_xy;
	u32 size;
	u32 src_xy;
	u32 color;
	u32 mode;
};

struct gpu {
	void __iomem *base;
	struct miscdevice misc;
};

static void gpu_write(struct gpu *g, u32 off, u32 val)
{
	writel(val, g->base + off);
}

static int gpu_open(struct inode *inode, struct file *filp)
{
	struct gpu *g = container_of(filp->private_data, struct gpu, misc);

	if (readl(g->base) != GPU_ID)
		return -ENODEV;
	filp->private_data = g;
	return 0;
}

static long gpu_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
{
	struct gpu *g = filp->private_data;
	struct gpu_regs regs;
	unsigned long left;

	if (cmd != 0x4750 || copy_from_user(&regs, (void __user *)arg, sizeof(regs)))
		return -EINVAL;
	left = 1000000;
	while (readl(g->base + 0x4) & 1) {
		if (!left--)
			return -ETIMEDOUT;
		cpu_relax();
	}
	gpu_write(g, 0x1c, regs.color);
	gpu_write(g, 0x20, regs.dst_xy);
	gpu_write(g, 0x24, regs.size);
	gpu_write(g, 0x28, regs.src_xy);
	gpu_write(g, 0x2c, regs.mode);
	gpu_write(g, 0x08, 1);
	return 0;
}

static const struct file_operations gpu_fops = {
	.owner = THIS_MODULE,
	.open = gpu_open,
	.unlocked_ioctl = gpu_ioctl,
};

static int gpu_probe(struct platform_device *pdev)
{
	struct gpu *g;
	struct resource *res;

	g = devm_kzalloc(&pdev->dev, sizeof(*g), GFP_KERNEL);
	if (!g)
		return -ENOMEM;
	res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	g->base = devm_ioremap_resource(&pdev->dev, res);
	if (IS_ERR(g->base))
		return PTR_ERR(g->base);
	g->misc.minor = MISC_DYNAMIC_MINOR;
	g->misc.name = "gpu-blit";
	g->misc.fops = &gpu_fops;
	g->misc.parent = &pdev->dev;
	platform_set_drvdata(pdev, g);
	return misc_register(&g->misc);
}

static void gpu_remove(struct platform_device *pdev)
{
	struct gpu *g = platform_get_drvdata(pdev);

	misc_deregister(&g->misc);
}

static const struct of_device_id gpu_of_match[] = {
	{ .compatible = "zcu106,gpu-blit" },
	{ }
};
MODULE_DEVICE_TABLE(of, gpu_of_match);

static struct platform_driver gpu_driver = {
	.probe = gpu_probe,
	.remove = gpu_remove,
	.driver = {
		.name = "gpu-blit",
		.of_match_table = gpu_of_match,
	},
};
module_platform_driver(gpu_driver);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("ZCU106 CVA6 desktop blit engine");
