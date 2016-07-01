package delight.nashornsandbox.internal

import delight.async.Value
import delight.nashornsandbox.NashornSandbox
import delight.nashornsandbox.exceptions.ScriptCPUAbuseException
import java.util.HashMap
import java.util.HashSet
import java.util.Map
import java.util.Random
import java.util.Set
import java.util.concurrent.ExecutorService
import javax.script.ScriptEngine
import javax.script.ScriptException
import jdk.nashorn.api.scripting.NashornScriptEngineFactory
import jdk.nashorn.api.scripting.ScriptObjectMirror

class NashornSandboxImpl implements NashornSandbox {

	val Set<String> allowedClasses
	val Map<String, Object> globalVariables

	var ScriptEngine scriptEngine
	var Long maxCPUTimeInMs = 0L
	var ExecutorService exectuor

	def void assertScriptEngine() {
		if (scriptEngine != null) {
			return
		}

		/*
		 * If eclipse shows an error here, see http://stackoverflow.com/a/10642163/270662
		 */
		val NashornScriptEngineFactory factory = new NashornScriptEngineFactory();

		scriptEngine = factory.getScriptEngine(new SandboxClassFilter(allowedClasses));

		scriptEngine.eval('var window = {};')
		scriptEngine.eval(BeautifyJs.CODE)
		for (entry : globalVariables.entrySet) {
			scriptEngine.put(entry.key, entry.value)
		}
		
		scriptEngine.eval("\n" +
                "quit = function() {};\n" +
                "exit = function() {};\n" +
                "\n" +
                "print = function() {};\n" +
                "echo = function() {};\n" +
                "\n" +
                "readFully = function() {};\n" +
                "readLine = function() {};\n" +
                "\n" +
                "load = function() {};\n" +
                "loadWithNewGlobal = function() {};\n" +
                "\n" +
                //"Java = null;\n" +
                "org = null;\n" +
                "java = null;\n" +
                "com = null;\n" +
                "sun = null;\n" +
                "net = null;\n" +
                "\n" +
                "$ARG = null;\n" +
                "$ENV = null;\n" +
                "$EXEC = null;\n" +
                "$OPTIONS = null;\n" +
                "$OUT = null;\n" +
                "$ERR = null;\n" +
                "$EXIT = null;\n" +
                "")
		
	}

	override Object eval(String js) {
		assertScriptEngine

		if (maxCPUTimeInMs == 0) {
			return scriptEngine.eval(js)
		}

		synchronized (this) {
			val resVal = new Value<Object>(null)
			val exceptionVal = new Value<Throwable>(null)

			val monitorThread = new MonitorThread(maxCPUTimeInMs * 1000000)

			if (exectuor == null) {
				throw new IllegalStateException(
					"When a CPU time limit is set, an executor needs to be provided by calling .setExecutor(...)")
			}

			val monitor = new Object()

			exectuor.execute([
				try {

					if (js.contains("intCheckForInterruption")) {
						throw new IllegalArgumentException(
							'Script contains the illegal string [intCheckForInterruption]')
					}

					val jsBeautify = scriptEngine.eval('window.js_beautify;') as ScriptObjectMirror

					val String beautifiedJs = jsBeautify.call("beautify", js) as String

					val randomToken = Math.abs(new Random().nextInt)

					val securedJs = '''
						var InterruptTest = Java.type('«InterruptTest.name»');
						var isInterrupted = InterruptTest.isInterrupted;
						var intCheckForInterruption«randomToken» = function() {
							if (isInterrupted()) {
							    throw new Error('Interrupted«randomToken»')
							}
						};
					''' +
						beautifiedJs.replaceAll(';\\n', ';intCheckForInterruption' + randomToken + '();\n').
							replace(') {', ') {intCheckForInterruption' + randomToken + '();\n')

					val mainThread = Thread.currentThread

					monitorThread.threadToMonitor = Thread.currentThread

					monitorThread.onInvalidHandler = [

						mainThread.interrupt

					]

					monitorThread.start

					try {
						val res = scriptEngine.eval(securedJs)
						resVal.set(res)
					} catch (ScriptException e) {
						if (e.message.contains("Interrupted" + randomToken)) {
							monitorThread.notifyOperationInterrupted

						} else {
							exceptionVal.set(e)
							monitorThread.stopMonitor
							synchronized (monitor) {
								monitor.notify

							}
							return;
						}
					} finally {
						monitorThread.stopMonitor

						synchronized (monitor) {
							monitor.notify

						}
					}

				} catch (Throwable t) {

					exceptionVal.set(t)
					monitorThread.stopMonitor
					synchronized (monitor) {
						monitor.notify

					}
				}
			])

			synchronized (monitor) {
				monitor.wait
			}

			if (monitorThread.CPULimitExceeded) {
				var notGraceful = ""
				if (!monitorThread.gracefullyInterrputed) {
					notGraceful = " The operation could not be gracefully interrupted."
				}

				throw new ScriptCPUAbuseException(
					"Script used more than the allowed [" + maxCPUTimeInMs + " ms] of CPU time. " + notGraceful,
					exceptionVal.get())
			}

			if (exceptionVal.get != null) {
				throw exceptionVal.get
			}

			resVal.get()

		}

	}

	override NashornSandbox setMaxCPUTime(long limit) {
		this.maxCPUTimeInMs = limit
		this
	}

	override NashornSandbox allow(Class<?> clazz) {
		allowedClasses.add(clazz.name)

		if (scriptEngine != null) {
			throw new IllegalStateException(
				"eval() was already called. Please specify all classes to be allowed/injected before calling eval()")
		}
		this
	}

	override NashornSandbox inject(String variableName, Object object) {
		this.globalVariables.put(variableName, object)
		if (!allowedClasses.contains(object.class.name)) {
			allow(object.class)
		}
		this
	}

	override NashornSandbox setExecutor(ExecutorService executor) {
		this.exectuor = executor
		this
	}

	override ExecutorService getExecutor() {
		this.exectuor
	}
	
	override get(String variableName) {
		assertScriptEngine
		scriptEngine.get(variableName)
	}
	
	new() {
		this.allowedClasses = new HashSet()
		this.globalVariables = new HashMap<String, Object>
		allow(InterruptTest)
	}
	
	

}
