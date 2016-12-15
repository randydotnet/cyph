#!/bin/bash

outputDir="$PWD"
cd $(cd "$(dirname "$0")"; pwd)/..
rootDir="$PWD"


cloneworkingdir=''
test=''
watch=''
minify=''

if [ "${1}" == '--watch' ] ; then
	watch=true
else
	if [ "${1}" != '--prod' ] ; then
		test=true
	fi
	if [ "${1}" != '--no-minify' ] ; then
		minify=true
	fi
fi

if [ ! -d ~/.build ] ; then
	cloneworkingdir=true
fi

tsfilesRoot="${outputDir}"
if [ "${cloneworkingdir}" -o "${test}" -o "${watch}" -o "${outputDir}" == "${rootDir}" ] ; then
	tsfilesRoot="${rootDir}"
	outputDir="${rootDir}/shared"
fi

if [ "${cloneworkingdir}" ] ; then
	mkdir ~/.build
	cp -rf * .babelrc ~/.build/
	cd ~/.build/
fi

tsfiles="$( \
	{ \
		find ${tsfilesRoot} -name '*.html' -not \( \
			-path "${tsfilesRoot}/.build/*" \
			-or -path "${tsfilesRoot}/websign/*" \
			-or -path '*/lib/*' \
		\) -exec cat {} \; | \
		grep -oP "src=(['\"])/js/.*?\1" & \
		grep -roP "importScripts\((['\"])/js/.*\1\)" shared/js & \
		echo cyph/analytics; \
	} | \
		perl -pe "s/.*?['\"]\/js\/(.*)\.js.*/\1/g" | \
		sort | \
		uniq | \
		grep -v 'Binary file' | \
		grep -v 'main.lib' | \
		grep -v 'translations' | \
		tr ' ' '\n' \
)"

cd shared

scssfiles="$(cd css ; find . -name '*.scss' | grep -v bourbon/ | perl -pe 's/\.\/(.*)\.scss/\1/g' | tr '\n' ' ')"


output=''

modulename () {
	m="$(echo ${1} | perl -pe 's/.*\/([^\/]+)$/\u$1/')"
	classM="$(grep -oiP "class\s+${m}" ${1}.ts | perl -pe 's/class\s+//')"

	if [ "${classM}" ] ; then
		echo "${classM}"
	else
		echo "${m}"
	fi
}

tsbuild () {
	node -e "
		const tsconfig	= JSON.parse(
			fs.readFileSync('tsconfig.json').toString()
		);

		tsconfig.compilerOptions.outDir	= '.';

		tsconfig.files	= 'preload/global ${*}'.
			trim().
			split(/\s+/).
			map(f => f + '.ts')
		;

		fs.writeFileSync(
			'tsconfig.json',
			JSON.stringify(tsconfig)
		);
	"

	output="${output}$(ngc -p . 2>&1)"
}

compile () {
	cd "${outputDir}"

	if [ "${cloneworkingdir}" ] ; then
		find . -mindepth 1 -maxdepth 1 -type d -not -name lib -exec bash -c '
			rm -rf ~/.build/shared/{} 2> /dev/null;
			cp -rf {} ~/.build/shared/;
		' \;
		cd ~/.build/shared
	fi

	for f in $scssfiles ; do
		command=" \
			scss -Icss css/${f}.scss \
				$(test "${minify}" && echo '| cleancss') \
			> ${outputDir}/css/${f}.css \
		"
		if [ "${watch}" ] ; then
			eval "${command}" &
		else
			output="${output}$(eval "${command}" 2>&1)"
		fi
	done

	cd js

	if [ "${test}" ] ; then
		output="${output}$(../../commands/tslint.sh 2>&1)"
	else
		for f in $tsfiles ; do
			node -e "
				const resolveReferences	= f => {
					const path		= fs.realpathSync(f);
					const parent	= path.split('/').slice(0, -1).join('/');

					return fs.readFileSync(path).toString().trim().replace(
						/\/\/\/ <reference path=\"(.*)\".*/g,
						(ref, sub) => sub.match(/\.d\.ts\$/) ?
							ref :
							\`export const _\${crypto.randomBytes(4).toString('hex')} = (() => {
								\${resolveReferences(parent + '/' + sub)}
							})();\`
					);
				};

				fs.writeFileSync(
					'${f}.ts',
					resolveReferences('${f}.ts')
				);
			"
		done
	fi

	tsbuild $(echo "$tsfiles" | grep -vP '/main$')

	for f in $(echo "$tsfiles" | grep -P '/main$') ; do
		tsbuild $f
		sed -i 's|./appmodule|./appmodule.ngfactory|g' "${f}.ts"
		sed -i 's|AppModule|AppModuleNgFactory|g' "${f}.ts"
		sed -i 's|bootstrapModule|bootstrapModuleFactory|g' "${f}.ts"
		tsbuild $f
	done

	if [ ! "${test}" ] ; then
		node -e 'console.log(`
			self.translations = ${JSON.stringify(
				child_process.spawnSync("find", [
					"../../translations",
					"-name",
					"*.json"
				]).stdout.toString().
					split("\n").
					filter(s => s).
					map(file => ({
						key: file.split("/").slice(-1)[0].split(".")[0],
						value: JSON.parse(fs.readFileSync(file).toString())
					})).
					reduce((translations, o) => {
						translations[o.key]	= o.value;
						return translations;
					}, {})
			)};
		`.trim())' > "${outputDir}/js/translations.js"

		mangleExcept="$(
			test "${minify}" && node -e "console.log(JSON.stringify('$({
				echo -e '
					crypto
					importScripts
					locals
					Thread
					threadSetupVars
				';
				{
					cat typings/globals.d.ts;
					find ../lib/typings -name '*.ts' -type f -exec cat {} \;;
				} |
					grep -oP 'declare.*:' |
					perl -pe 's/declare\s+.*?\s+(.*?):.*/\1/g' \
				;
				find . -name '*.ts' -type f -exec cat {} \; |
					tr -d '\n' |
					grep -oP 'new Thread\(.*?\;' |
					perl -pe 's/\/\*.*?\*\///g' |
					perl -pe 's/(.*)\{.*?;$/\1/g' |
					grep -oP '[A-Za-z0-9_$]+' \
				;
			} | sort | uniq | tr '\n' ' ')'.trim().split(/\s+/)))"
		)"

		for f in $tsfiles ; do
			m="$(modulename "${f}")"

			# Don't use ".js" file extension for Webpack outputs. No idea
			# why right now, but it breaks the module imports in Session.
			cat > "${f}.webpack.js" <<- EOM
				const webpack	= require('webpack');

				module.exports	= {
					entry: {
						app: './${f}.js'
					},
					$(test "${watch}" || echo "
						module: {
							rules: [
								{
									test: /\.js(\.tmp)?$/,
									exclude: /node_modules/,
									use: [
										{
											loader: 'babel-loader',
											options: {
												compact: false,
												presets: [
													['es2015', {modules: false}]
												]
											}
										}
									]
								}
							]
						},
					")
					output: {
						filename: './${f}.js.tmp',
						library: '${m}',
						libraryTarget: 'var'
					},
					plugins: [
						$(test "${minify}" && echo "
							new webpack.LoaderOptionsPlugin({
								debug: false,
								minimize: true
							}),
							new webpack.optimize.UglifyJsPlugin({
								compress: false,
								mangle: {
									except: ${mangleExcept}
								},
								output: {
									comments: false
								},
								sourceMap: false,
								test: /\.js(\.tmp)?$/
							}),
						")
						$(test "${m}" == 'Main' && echo "
							new webpack.optimize.CommonsChunkPlugin({
								name: 'lib',
								filename: './${f}.lib.js.tmp',
								minChunks: module => /\/lib\//.test(module.resource)
							})
						")
					]
				};
			EOM

			webpack --config "${f}.webpack.js"
		done

		babel --presets es2015 --compact false preload/global.js -o preload/global.js
		if [ "${minify}" ] ; then
			uglifyjs preload/global.js -o preload/global.js
		fi

		for f in $tsfiles ; do
			m="$(modulename "${f}")"

			if [ "${m}" == 'Main' ] ; then
				cat "${f}.lib.js.tmp" | sed 's|use strict||g' > "${outputDir}/js/${f}.lib.js"
				rm "${f}.lib.js.tmp"
			fi

			{
				cat preload/global.js;
				echo '(function () {'
				cat "${f}.js.tmp";
				echo "
					self.${m}	= ${m};

					var keys	= Object.keys(${m});
					for (var i = 0 ; i < keys.length ; ++i) {
						var key		= keys[i];
						self[key]	= ${m}[key];
					}
				" |
					if [ "${minify}" ] ; then uglifyjs ; else cat - ; fi \
				;
				echo '})();'
			} | \
				sed 's|use strict||g' \
			> "${outputDir}/js/${f}.js"

			rm "${f}.js.tmp"
		done

		for js in $(find . -name '*.js' -not -name 'translations.js') ; do
			delete=true
			for f in $tsfiles ; do
				if [ "${js}" == "./${f}.js" -o "${js}" == "./${f}.lib.js" ] ; then
					delete=''
				fi
			done
			if [ "${delete}" ] ; then
				rm "${js}"
			fi
		done
	fi
}

litedeploy () {
	cd ~/.litedeploy

	version="lite-${username}-${branch}"
	deployedBackend="https://${version}-dot-cyphme.appspot.com"
	localBackend='${locationData.protocol}//${locationData.hostname}:42000'

	sed -i "s|staging|${version}|g" default/config.go
	sed -i "s|${localBackend}|${deployedBackend}|g" cyph.im/js/cyph.im/main.js
	cat cyph.im/cyph-im.yaml | perl -pe 's/(- url: .*)/\1\n  login: admin/g' > yaml.new
	mv yaml.new cyph.im/cyph-im.yaml

	gcloud app deploy --quiet --no-promote --project cyphme --version $version */*.yaml

	cd
	rm -rf ~/.litedeploy

	echo -e "\n\n\nFinished deploying\n\n"
}

if [ "${watch}" ] ; then
	eval "$(${rootDir}/commands/getgitdata.sh)"

	liteDeployInterval=1800 # 30 minutes
	SECONDS=$liteDeployInterval

	while true ; do
		start="$(date +%s)"
		echo -e '\n\n\nBuilding JS/CSS\n\n'
		output=''
		compile
		echo -e "${output}\n\n\nFinished building JS/CSS ($(expr $(date +%s) - $start)s)\n\n"
		${rootDir}/commands/tslint.sh &

		#if [ $SECONDS -gt $liteDeployInterval -a ! -d ~/.litedeploy ] ; then
		#	echo -e "\n\n\nDeploying to lite env\n\n"
		#	mkdir ~/.litedeploy
		#	cp -rf "${rootDir}/default" "${rootDir}/cyph.im" ~/.litedeploy/
		#	litedeploy &
		#	SECONDS=0
		#fi

		cd "${rootDir}/shared"
		inotifywait -r --exclude '(node_modules|sed.*|.*\.(css|js|map|tmp))$' css js templates
	done
else
	compile
fi

echo -e "${output}"
exit ${#output}
