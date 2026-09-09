platform ""
	requires {
		main : () -> Elem
	}
	exposes [Elem, Signal, Gui, Ui, Rows, Files]
	packages {
		roc: "nightly-2026-09-09-7dadc35",
		http: "https://github.com/roc-lang/http/releases/download/0.1/6LcdNq2r7xTBwj972ecYWUkMWobJr94yL2NyJpHRAXap.tar.zst",
	}
	provides { "roc_ui_init": ui_init }
	hosted {
		"roc_each_bool_sink_push": EachSink.push_bool!,
		"roc_rows_delta_clear_sink_push": EachSink.push_delta_clear!,
		"roc_rows_delta_description_sink_push": EachSink.push_delta_description!,
		"roc_rows_delta_insert_sink_push": EachSink.push_delta_insert!,
		"roc_rows_delta_move_range_sink_push": EachSink.push_delta_move_range!,
		"roc_rows_delta_remove_range_sink_push": EachSink.push_delta_remove_range!,
		"roc_rows_delta_update_sink_push": EachSink.push_delta_update!,
		"roc_rows_snapshot_description_sink_push": EachSink.push_snapshot_description!,
		"roc_rows_snapshot_sink_push": EachSink.push_snapshot!,
		"roc_host_value_clone": HostValue.clone!,
		"roc_host_value_get_with_capability": HostValue.get_with_capability!,
		"roc_host_value_get_with_split": HostValue.get_with_split!,
		"roc_host_value_store_with_capability": HostValue.store_with_capability!,
		"roc_host_value_store_with_existing_capability": HostValue.store_with_existing_capability!,
		"roc_host_value_take_with_capability": HostValue.take_with_capability!,
		"roc_host_value_take_with_split": HostValue.take_with_split!,
		"roc_rows_same_generation_callable": Rows.same_generation_callable!,
	}
	targets: {
		inputs_dir: "targets/",
		arm64mac: { inputs: ["libsignals_gpui_host.a", "libengine.a", app, "../macos-sysroot/usr/lib/libSystem.tbd", "../macos-sysroot/usr/lib/libobjc.tbd", "../macos-sysroot/usr/lib/libc++.tbd"] },
		x64glibc: { inputs: ["crt1.o", "libsignals_gpui_host.a", "libengine.a", app, "libfreetype.so", "libxkbcommon.so", "libxkbcommon-x11.so", "libunwind.a", "libc_nonshared.a", "libm.so", "libc.so"] },
		x64mingw: { inputs: ["crt2.obj", "libsignals_gpui_host.a", "libengine.a", "signals.res", app, "api-ms-win-crt-conio-l1-1-0.lib", "api-ms-win-crt-convert-l1-1-0.lib", "api-ms-win-crt-environment-l1-1-0.lib", "api-ms-win-crt-filesystem-l1-1-0.lib", "api-ms-win-crt-heap-l1-1-0.lib", "api-ms-win-crt-locale-l1-1-0.lib", "api-ms-win-crt-math-l1-1-0.lib", "api-ms-win-crt-multibyte-l1-1-0.lib", "api-ms-win-crt-private-l1-1-0.lib", "api-ms-win-crt-process-l1-1-0.lib", "api-ms-win-crt-runtime-l1-1-0.lib", "api-ms-win-crt-stdio-l1-1-0.lib", "api-ms-win-crt-string-l1-1-0.lib", "api-ms-win-crt-time-l1-1-0.lib", "api-ms-win-crt-utility-l1-1-0.lib", "compiler_rt.lib", "libmingw32.lib", "ubsan_rt.lib", "unwind.lib", "zigc.lib", "ole32.lib", "activeds.lib", "advapi32.lib", "advpack.lib", "amsi.lib", "api-ms-win-appmodel-runtime-l1-1-1.lib", "api-ms-win-appmodel-runtime-l1-1-3.lib", "api-ms-win-appmodel-runtime-l1-1-6.lib", "api-ms-win-core-apiquery-l2-1-0.lib", "api-ms-win-core-backgroundtask-l1-1-0.lib", "api-ms-win-core-comm-l1-1-1.lib", "api-ms-win-core-comm-l1-1-2.lib", "api-ms-win-core-enclave-l1-1-1.lib", "api-ms-win-core-errorhandling-l1-1-3.lib", "api-ms-win-core-featurestaging-l1-1-0.lib", "api-ms-win-core-featurestaging-l1-1-1.lib", "api-ms-win-core-file-fromapp-l1-1-0.lib", "api-ms-win-core-handle-l1-1-0.lib", "api-ms-win-core-ioring-l1-1-0.lib", "api-ms-win-core-libraryloader-l2-1-0.lib", "api-ms-win-core-marshal-l1-1-0.lib", "api-ms-win-core-memory-l1-1-3.lib", "api-ms-win-core-memory-l1-1-4.lib", "api-ms-win-core-memory-l1-1-5.lib", "api-ms-win-core-memory-l1-1-6.lib", "api-ms-win-core-memory-l1-1-7.lib", "api-ms-win-core-memory-l1-1-8.lib", "api-ms-win-core-path-l1-1-0.lib", "api-ms-win-core-psm-appnotify-l1-1-0.lib", "api-ms-win-core-psm-appnotify-l1-1-1.lib", "api-ms-win-core-realtime-l1-1-1.lib", "api-ms-win-core-realtime-l1-1-2.lib", "api-ms-win-core-slapi-l1-1-0.lib", "api-ms-win-core-state-helpers-l1-1-0.lib", "api-ms-win-core-synch-l1-2-0.lib", "api-ms-win-core-sysinfo-l1-2-0.lib", "api-ms-win-core-sysinfo-l1-2-3.lib", "api-ms-win-core-sysinfo-l1-2-4.lib", "api-ms-win-core-sysinfo-l1-2-6.lib", "api-ms-win-core-util-l1-1-1.lib", "api-ms-win-core-winrt-error-l1-1-0.lib", "api-ms-win-core-winrt-error-l1-1-1.lib", "api-ms-win-core-winrt-l1-1-0.lib", "api-ms-win-core-winrt-registration-l1-1-0.lib", "api-ms-win-core-winrt-string-l1-1-0.lib", "api-ms-win-core-winrt-string-l1-1-1.lib", "api-ms-win-core-wow64-l1-1-1.lib", "api-ms-win-devices-query-l1-1-0.lib", "api-ms-win-devices-query-l1-1-1.lib", "api-ms-win-dx-d3dkmt-l1-1-0.lib", "api-ms-win-dx-d3dkmt-l1-1-4.lib", "api-ms-win-dx-d3dkmt-l1-1-6.lib", "api-ms-win-gaming-deviceinformation-l1-1-0.lib", "api-ms-win-gaming-expandedresources-l1-1-0.lib", "api-ms-win-gaming-tcui-l1-1-0.lib", "api-ms-win-gaming-tcui-l1-1-1.lib", "api-ms-win-gaming-tcui-l1-1-2.lib", "api-ms-win-gaming-tcui-l1-1-3.lib", "api-ms-win-gaming-tcui-l1-1-4.lib", "api-ms-win-mm-misc-l1-1-1.lib", "api-ms-win-net-isolation-l1-1-0.lib", "api-ms-win-security-base-l1-2-2.lib", "api-ms-win-security-isolatedcontainer-l1-1-0.lib", "api-ms-win-security-isolatedcontainer-l1-1-1.lib", "api-ms-win-service-core-l1-1-3.lib", "api-ms-win-service-core-l1-1-4.lib", "api-ms-win-service-core-l1-1-5.lib", "api-ms-win-shcore-scaling-l1-1-0.lib", "api-ms-win-shcore-scaling-l1-1-1.lib", "api-ms-win-shcore-scaling-l1-1-2.lib", "api-ms-win-shcore-stream-winrt-l1-1-0.lib", "api-ms-win-wsl-api-l1-1-0.lib", "apphelp.lib", "authz.lib", "avicap32.lib", "avifil32.lib", "avrt.lib", "bcp47mrm.lib", "bcrypt.lib", "bcryptprimitives.lib", "bluetoothapis.lib", "bthprops.lib", "cabinet.lib", "certadm.lib", "certpoleng.lib", "cfgmgr32.lib", "chakra.lib", "cldapi.lib", "clfs.lib", "clfsw32.lib", "clusapi.lib", "combase.lib", "comctl32.lib", "comdlg32.lib", "compstui.lib", "computecore.lib", "computenetwork.lib", "computestorage.lib", "comsvcs.lib", "coremessaging.lib", "credui.lib", "crypt32.lib", "cryptnet.lib", "cryptui.lib", "cryptxml.lib", "cscapi.lib", "d2d1.lib", "d3d11.lib", "d3dcompiler_47.lib", "d3dcsx.lib", "davclnt.lib", "dbgeng.lib", "dbghelp.lib", "dbgmodel.lib", "dciman32.lib", "dcomp.lib", "dflayout.lib", "dhcpcsvc.lib", "dhcpcsvc6.lib", "dhcpsapi.lib", "diagnosticdataquery.lib", "dinput8.lib", "dmprocessxmlfiltered.lib", "dnsapi.lib", "drt.lib", "drtprov.lib", "drttransport.lib", "dsparse.lib", "dsprop.lib", "dssec.lib", "dsuiext.lib", "dwmapi.lib", "dwrite.lib", "dxgi.lib", "dxva2.lib", "eappcfg.lib", "eappprxy.lib", "efswrt.lib", "elscore.lib", "esent.lib", "faultrep.lib", "fhsvcctl.lib", "firewallapi.lib", "fltlib.lib", "fltmgr.lib", "fontsub.lib", "fwpkclnt.lib", "fwpuclnt.lib", "fxsutility.lib", "gdi32.lib", "gdiplus.lib", "glu32.lib", "gpedit.lib", "hal.lib", "hhctrl.lib", "hid.lib", "hlink.lib", "httpapi.lib", "icm32.lib", "icmui.lib", "icu.lib", "icuin.lib", "icuuc.lib", "ieframe.lib", "imagehlp.lib", "imgutil.lib", "imm32.lib", "infocardapi.lib", "inkobjcore.lib", "iphlpapi.lib", "iscsidsc.lib", "isolatedwindowsenvironmentutils.lib", "kernel32.lib", "kernelbase.lib", "keycredmgr.lib", "ksecdd.lib", "ksproxy.lib", "ksuser.lib", "ktmw32.lib", "licenseprotection.lib", "loadperf.lib", "magnification.lib", "mapi32.lib", "mdmlocalmanagement.lib", "mdmregistration.lib", "mgmtapi.lib", "mi.lib", "mmdevapi.lib", "mpr.lib", "mprapi.lib", "mqrt.lib", "mrmsupport.lib", "msacm32.lib", "msajapi.lib", "mscms.lib", "mscoree.lib", "msctfmonitor.lib", "msdelta.lib", "msdmo.lib", "msdrm.lib", "msi.lib", "msimg32.lib", "mspatcha.lib", "mspatchc.lib", "msports.lib", "msrating.lib", "mssign32.lib", "mstask.lib", "msvfw32.lib", "mswsock.lib", "mtxdm.lib", "ncrypt.lib", "ndfapi.lib", "ndis.lib", "netapi32.lib", "netsh.lib", "netshell.lib", "newdev.lib", "ninput.lib", "normaliz.lib", "ntdll.lib", "ntdllk.lib", "ntdsapi.lib", "ntlanman.lib", "ntoskrnl.lib", "odbc32.lib", "odbcbcp.lib", "offreg.lib", "oleacc.lib", "oleaut32.lib", "oledlg.lib", "ondemandconnroutehelper.lib", "opengl32.lib", "p2p.lib", "p2pgraph.lib", "pdh.lib", "peerdist.lib", "powrprof.lib", "prntvpt.lib", "projectedfslib.lib", "propsys.lib", "psapi.lib", "pshed.lib", "query.lib", "qwave.lib", "rasapi32.lib", "rasdlg.lib", "resutils.lib", "rpcns4.lib", "rpcproxy.lib", "rpcrt4.lib", "rstrtmgr.lib", "rtm.lib", "rtutils.lib", "rtworkq.lib", "sas.lib", "scarddlg.lib", "schannel.lib", "sechost.lib", "secur32.lib", "sensapi.lib", "sensorsutilsv2.lib", "setupapi.lib", "sfc.lib", "shdocvw.lib", "shell32.lib", "shlwapi.lib", "slc.lib", "slcext.lib", "slwga.lib", "snmpapi.lib", "spoolss.lib", "srclient.lib", "srpapi.lib", "sspicli.lib", "sti.lib", "t2embed.lib", "tapi32.lib", "tbs.lib", "tdh.lib", "tokenbinding.lib", "traffic.lib", "txfw32.lib", "ualapi.lib", "uiautomationcore.lib", "urlmon.lib", "user32.lib", "userenv.lib", "usp10.lib", "uxtheme.lib", "verifier.lib", "version.lib", "vertdll.lib", "vhfum.lib", "virtdisk.lib", "vmdevicehost.lib", "vmsavedstatedumpprovider.lib", "wcmapi.lib", "wdsbp.lib", "wdsclientapi.lib", "wdsmc.lib", "wdspxe.lib", "wdstptc.lib", "webauthn.lib", "webservices.lib", "websocket.lib", "wecapi.lib", "wer.lib", "wevtapi.lib", "winbio.lib", "windows.media.mediacontrol.lib", "windows.networking.lib", "windows.ui.lib", "windowscodecs.lib", "winfax.lib", "winhttp.lib", "winhvemulation.lib", "winhvplatform.lib", "wininet.lib", "winmm.lib", "winscard.lib", "winspool.lib", "wintrust.lib", "winusb.lib", "wlanapi.lib", "wlanui.lib", "wldap32.lib", "wldp.lib", "wmvcore.lib", "wnvapi.lib", "wofutil.lib", "ws2_32.lib", "wscapi.lib", "wsclient.lib", "wsdapi.lib", "wsmsvc.lib", "wsnmp32.lib", "wtsapi32.lib", "xinput1_4.lib", "xolehlp.lib"] },
	}

import Elem exposing [Elem]
import EachSink
import HostValue
import Signal
import Gui
import Files
import Ui
import Rows

ui_init : () -> Box(Elem)
ui_init = || {
	Box.box(main())
}
