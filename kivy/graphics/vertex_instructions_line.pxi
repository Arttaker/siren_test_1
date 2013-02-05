DEF LINE_CAP_NONE = 0
DEF LINE_CAP_SQUARE = 1
DEF LINE_CAP_ROUND = 2

DEF LINE_JOINT_NONE = 0
DEF LINE_JOINT_MITER = 1
DEF LINE_JOINT_BEVEL = 2
DEF LINE_JOINT_ROUND = 3

DEF LINE_MODE_POINTS = 0
DEF LINE_MODE_ELLIPSE = 1
DEF LINE_MODE_CIRCLE = 2
DEF LINE_MODE_RECTANGLE = 3
DEF LINE_MODE_BEZIER = 4

from kivy.graphics.stencil_instructions cimport StencilUse, StencilUnUse, StencilPush, StencilPop

cdef inline int line_intersection(double x1, double y1, double x2, double y2,
        double x3, double y3, double x4, double y4, double *px, double *py):
    cdef double u = (x1 * y2 - y1 * x2)
    cdef double v = (x3 * y4 - y3 * x4)
    cdef double denom = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
    if denom == 0:
        return 0
    px[0] = (u * (x3 - x4) - (x1 - x2) * v) / denom
    py[0] = (u * (y3 - y4) - (y1 - y2) * v) / denom
    return 1

cdef class Line(VertexInstruction):
    '''A 2d line.

    Drawing a line can be done easily::

        with self.canvas:
            Line(points=[100, 100, 200, 100, 100, 200], width=10)

    Actually, the line have 3 internal drawing mode that you should know about
    if you want to get the best performance of it:

    #. If the :data:`width` is 1.0, then we will use standard GL_LINE drawing
       from OpenGL. :data:`dash_length` and :data:`dash_offset` works, while
       properties for cap and joint have no sense for this.
    #. If the :data:`width` is > 1.0, then we will use a custom drawing method,
       based on triangles. :data:`dash_length` and :data:`dash_offset` is not
       working on that mode.
       Additionally, if the current color have an alpha < 1.0, stencil will be
       used internally to draw the line.

    .. image:: images/line-instruction.png
        :align: center

    :Parameters:
        `points`: list
            List of points in the format (x1, y1, x2, y2...)
        `dash_length`: int
            Length of a segment (if dashed), default 1
        `dash_offset`: int
            Offset between the end of a segments and the begining of the
            next one, default 0, changing this makes it dashed.
        `width`: float
            Width of the line, default 1.0
        `cap`: str, default to 'round'
            See :data:`cap` for more information.
        `joint`: str, default to 'round'
            See :data:`joint` for more information.
        `cap_precision`: int, default to 10
            See :data:`cap_precision` for more information
        `joint_precision`: int, default to 10
            See :data:`joint_precision` for more information
        `close`: bool, default to False
            If True, the line will be closed.
        `circle`: list
            If set, the :data:`points` will be set to build a circle. Check
            :data:`circle` for more information.
        `ellipse`: list
            If set, the :data:`points` will be set to build an ellipse. Check
            :data:`ellipse` for more information.
        `rectangle`: list
            If set, the :data:`points` will be set to build a rectangle. Check
            :data:`rectangle` for more information.
        `bezier`: list
            If set, the :data:`points` will be set to build a bezier line. Check
            :data:`bezier` for more information.
        `bezier_precision`: int, default to 180
            Precision of the Bezier drawing.

    .. versionadded:: 1.0.8
        `dash_offset` and `dash_length` have been added

    .. versionadded:: 1.4.1
        `width`, `cap`, `joint`, `cap_precision`, `joint_precision`, `close`,
        `ellipse`, `rectangle` have been added.

    .. versionadded:: 1.4.1
        `bezier`, `bezier_precision` have been added.
    '''
    cdef int _cap
    cdef int _cap_precision
    cdef int _joint_precision
    cdef int _bezier_precision
    cdef int _joint
    cdef list _points
    cdef float _width
    cdef int _dash_offset, _dash_length
    cdef int _use_stencil
    cdef int _close
    cdef int _mode
    cdef Instruction _stencil_rect
    cdef Instruction _stencil_push
    cdef Instruction _stencil_use
    cdef Instruction _stencil_unuse
    cdef Instruction _stencil_pop
    cdef double _bxmin, _bxmax, _bymin, _bymax
    cdef tuple _mode_args

    def __init__(self, **kwargs):
        VertexInstruction.__init__(self, **kwargs)
        v = kwargs.get('points')
        self.points = v if v is not None else []
        self.batch.set_mode('line_strip')
        self._dash_length = kwargs.get('dash_length') or 1
        self._dash_offset = kwargs.get('dash_offset') or 0
        self._width = kwargs.get('width') or 1.0
        self.joint = kwargs.get('joint') or 'round'
        self.cap = kwargs.get('cap') or 'round'
        self._cap_precision = kwargs.get('cap_precision') or 10
        self._joint_precision = kwargs.get('joint_precision') or 10
        self._bezier_precision = kwargs.get('bezier_precision') or 180
        self._close = int(bool(kwargs.get('close', 0)))
        self._stencil_rect = None
        self._stencil_push = None
        self._stencil_use = None
        self._stencil_unuse = None
        self._stencil_pop = None
        self._use_stencil = 0

        if 'ellipse' in kwargs:
            self.ellipse = kwargs['ellipse']
        if 'circle' in kwargs:
            self.circle = kwargs['circle']
        if 'rectangle' in kwargs:
            self.rectangle = kwargs['rectangle']
        if 'bezier' in kwargs:
            self.bezier = kwargs['bezier']

    cdef void build(self):
        if self._mode == LINE_MODE_ELLIPSE:
            self.prebuild_ellipse()
        elif self._mode == LINE_MODE_CIRCLE:
            self.prebuild_circle()
        elif self._mode == LINE_MODE_RECTANGLE:
            self.prebuild_rectangle()
        elif self._mode == LINE_MODE_BEZIER:
            self.prebuild_bezier()
        if self._width == 1.0:
            self.build_legacy()
        else:
            self.build_extended()

    cdef void ensure_stencil(self):
        if self._stencil_rect == None:
            self._stencil_rect = Rectangle()
            self._stencil_push = StencilPush()
            self._stencil_pop = StencilPop()
            self._stencil_use = StencilUse(op='lequal')
            self._stencil_unuse = StencilUnUse()

    cdef void apply(self):
        if self._width == 1.:
            VertexInstruction.apply(self)
            return

        cdef double alpha = getActiveContext()['color'][-1]
        self._use_stencil = alpha < 1
        if self._use_stencil:
            self.ensure_stencil()

            self._stencil_push.apply()
            VertexInstruction.apply(self)
            self._stencil_use.apply()
            self._stencil_rect.pos = self._bxmin, self._bymin
            self._stencil_rect.size = self._bxmax - self._bxmin, self._bymax - self._bymin
            self._stencil_rect.apply()
            self._stencil_unuse.apply()
            VertexInstruction.apply(self)
            self._stencil_pop.apply()
        else:
            VertexInstruction.apply(self)

    cdef void build_legacy(self):
        cdef int i, count = len(self.points) / 2
        cdef list p = self.points
        cdef vertex_t *vertices = NULL
        cdef unsigned short *indices = NULL
        cdef float tex_x
        cdef char *buf = NULL
        cdef Texture texture = self.texture

        if count < 2:
            self.batch.clear_data()
            return

        if self._close:
            p = p + [p[0], p[1]]
            count += 1

        self.batch.set_mode('line_strip')
        if self._dash_offset != 0:
            if texture is None or texture._width != \
                (self._dash_length + self._dash_offset) or \
                texture._height != 1:

                self.texture = texture = Texture.create(
                        size=(self._dash_length + self._dash_offset, 1))
                texture.wrap = 'repeat'

            # create a buffer to fill our texture
            buf = <char *>malloc(4 * (self._dash_length + self._dash_offset))
            memset(buf, 255, self._dash_length * 4)
            memset(buf + self._dash_length * 4, 0, self._dash_offset * 4)
            p_str = PyString_FromStringAndSize(buf,  (self._dash_length + self._dash_offset) * 4)

            self.texture.blit_buffer(p_str, colorfmt='rgba', bufferfmt='ubyte')
            free(buf)

        elif texture is not None:
            self.texture = None

        vertices = <vertex_t *>malloc(count * sizeof(vertex_t))
        if vertices == NULL:
            raise MemoryError('vertices')

        indices = <unsigned short *>malloc(count * sizeof(unsigned short))
        if indices == NULL:
            free(vertices)
            raise MemoryError('indices')

        tex_x = 0
        for i in xrange(count):
            if self._dash_offset != 0 and i > 0:
                tex_x += sqrt(
                        pow(p[i * 2]     - p[(i - 1) * 2], 2)  +
                        pow(p[i * 2 + 1] - p[(i - 1) * 2 + 1], 2)) / (
                                self._dash_length + self._dash_offset)

                vertices[i].s0 = tex_x
                vertices[i].t0 = 0

            vertices[i].x = p[i * 2]
            vertices[i].y = p[i * 2 + 1]
            indices[i] = i

        self.batch.set_data(vertices, count, indices, count)

        free(vertices)
        free(indices)

    cdef void build_extended(self):
        cdef int i, j, count = len(self.points) / 2
        cdef list p = self.points
        cdef vertex_t *vertices = NULL
        cdef unsigned short *indices = NULL
        cdef float tex_x
        cdef int cap
        cdef char *buf = NULL
        cdef Texture texture = self.texture

        self._bxmin = 999999999
        self._bymin = 999999999
        self._bxmax = -999999999
        self._bymax = -999999999

        if count < 2:
            self.batch.clear_data()
            return

        cap = self._cap
        if self._close and count > 2:
            p = p + p[0:4]
            count += 2
            cap = LINE_CAP_NONE

        self.batch.set_mode('triangles')
        cdef unsigned int vertices_count = (count - 1) * 4
        cdef unsigned int indices_count = (count - 1) * 6
        cdef unsigned int iv = 0, ii = 0

        if self._joint == LINE_JOINT_BEVEL:
            indices_count += (count - 2) * 3
            vertices_count += (count - 2)
        elif self._joint == LINE_JOINT_ROUND:
            indices_count += (self._joint_precision * 3) * (count - 2)
            vertices_count += (self._joint_precision) * (count - 2)
        elif self._joint == LINE_JOINT_MITER:
            indices_count += (count - 2) * 6
            vertices_count += (count - 2) * 2

        if cap == LINE_CAP_SQUARE:
            indices_count += 12
            vertices_count += 4
        elif cap == LINE_CAP_ROUND:
            indices_count += (self._cap_precision * 3) * 2
            vertices_count += (self._cap_precision) * 2

        vertices = <vertex_t *>malloc(vertices_count * sizeof(vertex_t))
        if vertices == NULL:
            raise MemoryError('vertices')

        indices = <unsigned short *>malloc(indices_count * sizeof(unsigned short))
        if indices == NULL:
            free(vertices)
            raise MemoryError('indices')

        cdef double ax, ay, bx, _by, cx, cy, angle, a1, a2
        cdef double x1, y1, x2, y2, x3, y3, x4, y4
        cdef double sx1, sy1, sx4, sy4, sangle
        cdef double pcx, pcy, px1, py1, px2, py2, px3, py3, px4, py4, pangle, pangle2
        cdef double w = self._width
        cdef double ix, iy
        cdef unsigned int piv, pii2, piv2
        cdef double jangle
        angle = sangle = 0
        piv = pcx = pcy = cx = cy = ii = iv = ix = iy = 0
        px1 = px2 = px3 = px4 = py1 = py2 = py3 = py4 = 0
        sx1 = sy1 = sx4 = sy4 = 0
        x1 = x2 = x3 = x4 = y1 = y2 = y3 = y4 = 0
        cdef double cos1 = 0, cos2 = 0, sin1 = 0, sin2 = 0
        for i in range(0, count - 1):
            ax = p[i * 2]
            ay = p[i * 2 + 1]
            bx = p[i * 2 + 2]
            _by = p[i * 2 + 3]

            if i > 0 and self._joint != LINE_JOINT_NONE:
                pcx = cx
                pcy = cy
                px1 = x1
                px2 = x2
                px3 = x3
                px4 = x4
                py1 = y1
                py2 = y2
                py3 = y3
                py4 = y4

            piv2 = piv
            piv = iv
            pangle2 = pangle
            pangle = angle

            # calculate the orientation of the segment, between pi and -pi
            cx = bx - ax
            cy = _by - ay
            angle = atan2(cy, cx)
            a1 = angle - PI2
            a2 = angle + PI2

            # calculate the position of the segment
            cos1 = cos(a1) * w
            sin1 = sin(a1) * w
            cos2 = cos(a2) * w
            sin2 = sin(a2) * w
            x1 = ax + cos1
            y1 = ay + sin1
            x4 = ax + cos2
            y4 = ay + sin2
            x2 = bx + cos1
            y2 = _by + sin1
            x3 = bx + cos2
            y3 = _by + sin2

            if i == 0:
                sx1 = x1
                sy1 = y1
                sx4 = x4
                sy4 = y4
                sangle = angle

            indices[ii    ] = iv
            indices[ii + 1] = iv + 1
            indices[ii + 2] = iv + 2
            indices[ii + 3] = iv
            indices[ii + 4] = iv + 2
            indices[ii + 5] = iv + 3
            ii += 6

            vertices[iv].x = x1
            vertices[iv].y = y1
            vertices[iv].s0 = 0
            vertices[iv].t0 = 0
            iv += 1
            vertices[iv].x = x2
            vertices[iv].y = y2
            vertices[iv].s0 = 0
            vertices[iv].t0 = 0
            iv += 1
            vertices[iv].x = x3
            vertices[iv].y = y3
            vertices[iv].s0 = 0
            vertices[iv].t0 = 0
            iv += 1
            vertices[iv].x = x4
            vertices[iv].y = y4
            vertices[iv].s0 = 0
            vertices[iv].t0 = 0
            iv += 1

            # joint generation
            if i == 0 or self._joint == LINE_JOINT_NONE:
                continue

            # calculate the angle of the previous and current segment
            jangle = atan2(
                cx * pcy - cy * pcx,
                cx * pcx + cy * pcy)

            # in case of the angle is NULL, avoid the generation
            if jangle == 0 or jangle == PI or jangle == -PI:
                if self._joint == LINE_JOINT_ROUND:
                    vertices_count -= self._joint_precision
                    indices_count -= self._joint_precision * 3
                elif self._joint == LINE_JOINT_BEVEL:
                    vertices_count -= 1
                    indices_count -= 3
                elif self._joint == LINE_JOINT_MITER:
                    vertices_count -= 2
                    indices_count -= 6
                continue

            if self._joint == LINE_JOINT_BEVEL:
                vertices[iv].x = ax
                vertices[iv].y = ay
                vertices[iv].s0 = 0
                vertices[iv].t0 = 0
                if jangle < 0:
                    indices[ii] = piv2 + 1
                    indices[ii + 1] = piv
                    indices[ii + 2] = iv
                else:
                    indices[ii] = piv2 + 2
                    indices[ii + 1] = piv + 3
                    indices[ii + 2] = iv
                ii += 3
                iv += 1

            elif self._joint == LINE_JOINT_MITER:
                vertices[iv].x = ax
                vertices[iv].y = ay
                vertices[iv].s0 = 0
                vertices[iv].t0 = 0
                if jangle < 0:
                    if line_intersection(px1, py1, px2, py2, x1, y1, x2, y2, &ix, &iy) == 0:
                        vertices_count -= 2
                        indices_count -= 6
                        continue
                    vertices[iv + 1].x = ix
                    vertices[iv + 1].y = iy
                    vertices[iv + 1].s0 = 0
                    vertices[iv + 1].t0 = 0
                    indices[ii] = iv
                    indices[ii + 1] = iv + 1
                    indices[ii + 2] = piv2 + 1
                    indices[ii + 3] = iv
                    indices[ii + 4] = piv
                    indices[ii + 5] = iv + 1
                    ii += 6
                    iv += 2
                else:
                    if line_intersection(px3, py3, px4, py4, x3, y3, x4, y4, &ix, &iy) == 0:
                        vertices_count -= 2
                        indices_count -= 6
                        continue
                    vertices[iv + 1].x = ix
                    vertices[iv + 1].y = iy
                    vertices[iv + 1].s0 = 0
                    vertices[iv + 1].t0 = 0
                    indices[ii] = iv
                    indices[ii + 1] = iv + 1
                    indices[ii + 2] = piv2 + 2
                    indices[ii + 3] = iv
                    indices[ii + 4] = piv + 3
                    indices[ii + 5] = iv + 1
                    ii += 6
                    iv += 2



            elif self._joint == LINE_JOINT_ROUND:

                # cap end
                if jangle < 0:
                    a1 = pangle2 - PI2
                    a2 = angle + PI2
                    a0 = a2
                    step = (abs(jangle)) / float(self._joint_precision)
                    pivstart = piv + 3
                    pivend = piv2 + 1
                else:
                    a1 = angle - PI2
                    a2 = pangle2 + PI2
                    a0 = a1
                    step = -(abs(jangle)) / float(self._joint_precision)
                    pivstart = piv
                    pivend = piv2 + 2
                siv = iv
                vertices[iv].x = ax
                vertices[iv].y = ay
                vertices[iv].s0 = 0
                vertices[iv].t0 = 0
                iv += 1
                for j in xrange(0, self._joint_precision - 1):
                    vertices[iv].x = ax - cos(a0 - step * j) * w
                    vertices[iv].y = ay - sin(a0 - step * j) * w
                    vertices[iv].s0 = 0
                    vertices[iv].t0 = 0
                    if j == 0:
                        indices[ii] = siv
                        indices[ii + 1] = pivstart
                        indices[ii + 2] = iv
                    else:
                        indices[ii] = siv
                        indices[ii + 1] = iv - 1
                        indices[ii + 2] = iv
                    iv += 1
                    ii += 3
                indices[ii] = siv
                indices[ii + 1] = iv - 1
                indices[ii + 2] = pivend
                ii += 3

        # caps
        if cap == LINE_CAP_SQUARE:
            vertices[iv].x = x2 + cos(angle) * w
            vertices[iv].y = y2 + sin(angle) * w
            vertices[iv].s0 = 0
            vertices[iv].t0 = 0
            vertices[iv + 1].x = x3 + cos(angle) * w
            vertices[iv + 1].y = y3 + sin(angle) * w
            vertices[iv + 1].s0 = 0
            vertices[iv + 1].t0 = 0
            indices[ii] = piv + 1
            indices[ii + 1] = piv + 2
            indices[ii + 2] = iv + 1
            indices[ii + 3] = piv + 1
            indices[ii + 4] = iv
            indices[ii + 5] = iv + 1
            ii += 6
            iv += 2
            vertices[iv].x = sx1 - cos(sangle) * w
            vertices[iv].y = sy1 - sin(sangle) * w
            vertices[iv].s0 = 0
            vertices[iv].t0 = 0
            vertices[iv + 1].x = sx4 - cos(sangle) * w
            vertices[iv + 1].y = sy4 - sin(sangle) * w
            vertices[iv + 1].s0 = 0
            vertices[iv + 1].t0 = 0
            indices[ii] = 0
            indices[ii + 1] = 3
            indices[ii + 2] = iv + 1
            indices[ii + 3] = 0
            indices[ii + 4] = iv
            indices[ii + 5] = iv + 1
            ii += 6
            iv += 2

        elif cap == LINE_CAP_ROUND:

            # cap start
            a1 = sangle - PI2
            a2 = sangle + PI2
            step = (a1 - a2) / float(self._cap_precision)
            siv = iv
            cx = p[0]
            cy = p[1]
            vertices[iv].x = cx
            vertices[iv].y = cy
            vertices[iv].s0 = 0
            vertices[iv].t0 = 0
            iv += 1
            for i in xrange(0, self._cap_precision - 1):
                vertices[iv].x = cx + cos(a1 + step * i) * w
                vertices[iv].y = cy + sin(a1 + step * i) * w
                vertices[iv].s0 = 0
                vertices[iv].t0 = 0
                if i == 0:
                    indices[ii] = siv
                    indices[ii + 1] = 0
                    indices[ii + 2] = iv
                else:
                    indices[ii] = siv
                    indices[ii + 1] = iv - 1
                    indices[ii + 2] = iv
                iv += 1
                ii += 3
            indices[ii] = siv
            indices[ii + 1] = iv - 1
            indices[ii + 2] = 3
            ii += 3

            # cap end
            a1 = angle - PI2
            a2 = angle + PI2
            step = (a2 - a1) / float(self._cap_precision)
            siv = iv
            cx = p[-2]
            cy = p[-1]
            vertices[iv].x = cx
            vertices[iv].y = cy
            vertices[iv].s0 = 0
            vertices[iv].t0 = 0
            iv += 1
            for i in xrange(0, self._cap_precision - 1):
                vertices[iv].x = cx + cos(a1 + step * i) * w
                vertices[iv].y = cy + sin(a1 + step * i) * w
                vertices[iv].s0 = 0
                vertices[iv].t0 = 0
                if i == 0:
                    indices[ii] = siv
                    indices[ii + 1] = piv + 1
                    indices[ii + 2] = iv
                else:
                    indices[ii] = siv
                    indices[ii + 1] = iv - 1
                    indices[ii + 2] = iv
                iv += 1
                ii += 3
            indices[ii] = siv
            indices[ii + 1] = iv - 1
            indices[ii + 2] = piv + 2
            ii += 3

        #print 'ii=', ii, 'indices_count=', indices_count
        #print 'iv=', iv, 'vertices_count', vertices_count

        # compute bbox
        for i in xrange(vertices_count):
            if vertices[i].x < self._bxmin:
                self._bxmin = vertices[i].x
            if vertices[i].x > self._bxmax:
                self._bxmax = vertices[i].x
            if vertices[i].y < self._bymin:
                self._bymin = vertices[i].y
            if vertices[i].y > self._bymax:
                self._bymax = vertices[i].y

        self.batch.set_data(vertices, vertices_count, indices, indices_count)

        free(vertices)
        free(indices)



    property points:
        '''Property for getting/settings points of the line

        .. warning::

            This will always reconstruct the whole graphics from the new points
            list. It can be very CPU expensive.
        '''
        def __get__(self):
            return self._points
        def __set__(self, points):
            self._points = list(points)
            self.flag_update()

    property dash_length:
        '''Property for getting/setting the length of the dashes in the curve

        .. versionadded:: 1.0.8
        '''
        def __get__(self):
            return self._dash_length

        def __set__(self, value):
            if value < 0:
                raise GraphicException('Invalid dash_length value, must be >= 0')
            self._dash_length = value
            self.flag_update()

    property dash_offset:
        '''Property for getting/setting the offset between the dashes in the curve

        .. versionadded:: 1.0.8
        '''
        def __get__(self):
            return self._dash_offset

        def __set__(self, value):
            if value < 0:
                raise GraphicException('Invalid dash_offset value, must be >= 0')
            self._dash_offset = value
            self.flag_update()

    property width:
        '''Determine the width of the line, default to 1.0.

        .. versionadded:: 1.4.1
        '''
        def __get__(self):
            return self._width

        def __set__(self, value):
            if value <= 0:
                raise GraphicException('Invalid width value, must be > 0')
            self._width = value
            self.flag_update()

    property cap:
        '''Determine the cap of the line, default to 'round'. Can be one of
        'none', 'square' or 'round'

        .. versionadded:: 1.4.1
        '''
        def __get__(self):
            if self._cap == LINE_CAP_SQUARE:
                return 'square'
            elif self._cap == LINE_CAP_ROUND:
                return 'round'
            return 'none'

        def __set__(self, value):
            if value not in ('none', 'square', 'round'):
                raise GraphicException('Invalid cap, must be one of '
                        '"none", "square", "round"')
            if value == 'square':
                self._cap = LINE_CAP_SQUARE
            elif value == 'round':
                self._cap = LINE_CAP_ROUND
            else:
                self._cap = LINE_CAP_NONE
            self.flag_update()

    property joint:
        '''Determine the join of the line, default to 'round'. Can be one of
        'none', 'round', 'bevel', 'miter'.

        .. versionadded:: 1.4.1
        '''

        def __get__(self):
            if self._joint == LINE_JOINT_ROUND:
                return 'round'
            elif self._joint == LINE_JOINT_BEVEL:
                return 'bevel'
            elif self._joint == LINE_JOINT_MITER:
                return 'miter'
            return 'none'

        def __set__(self, value):
            if value not in ('none', 'miter', 'bevel', 'round'):
                raise GraphicException('Invalid joint, must be one of '
                    '"none", "miter", "bevel", "round"')
            if value == 'round':
                self._joint = LINE_JOINT_ROUND
            elif value == 'bevel':
                self._joint = LINE_JOINT_BEVEL
            elif value == 'miter':
                self._joint = LINE_JOINT_MITER
            else:
                self._joint = LINE_JOINT_NONE
            self.flag_update()

    property cap_precision:
        '''Number of iteration for drawing the "round" cap, default to 10.
        The cap_precision must be at least 1.

        .. versionadded:: 1.4.1
        '''

        def __get__(self):
            return self._cap_precision

        def __set__(self, value):
            if value < 1:
                raise GraphicException('Invalid cap_precision value, must be >= 1')
            self._cap_precision = int(value)
            self.flag_update()

    property joint_precision:
        '''Number of iteration for drawing the "round" joint, default to 10.
        The joint_precision must be at least 1.

        .. versionadded:: 1.4.1
        '''

        def __get__(self):
            return self._joint_precision

        def __set__(self, value):
            if value < 1:
                raise GraphicException('Invalid joint_precision value, must be >= 1')
            self._joint_precision = int(value)
            self.flag_update()

    property close:
        '''If True, the line will be closed.

        .. versionadded:: 1.4.1
        '''

        def __get__(self):
            return self._close

        def __set__(self, value):
            self._close = int(bool(value))
            self.flag_update()

    property ellipse:
        '''Use this property to build an ellipse, without calculate the
        :data:`points`. You can only set this property, not get it.

        The argument must be a tuple of (x, y, width, height, angle_start,
        angle_end, segments):

        * x and y represent the bottom left of the ellipse
        * width and height represent the size of the ellipse
        * (optional) angle_start and angle_end are in degree. The default
            value is 0 and 360.
        * (optional) segments is the precision of the ellipse. The default
            value is calculated from the range between angle.

        Note that it's up to you to :data:`close` the ellipse or not.

        For example, for building a simple ellipse, in python::

            # simple ellipse
            Line(ellipse=(0, 0, 150, 150))

            # only from 90 to 180 degrees
            Line(ellipse=(0, 0, 150, 150, 90, 180))

            # only from 90 to 180 degrees, with few segments
            Line(ellipse=(0, 0, 150, 150, 90, 180, 20))

        .. versionadded:: 1.4.1
        '''

        def __set__(self, args):
            if args == None:
                raise GraphicException(
                        'Invalid ellipse value: {0!r}'.format(args))
            if len(args) not in (4, 6, 7):
                raise GraphicException('Invalid number of arguments: '
                        '{0} instead of 4, 6 or 7.'.format(len(args)))
            self._mode_args = tuple(args)
            self._mode = LINE_MODE_ELLIPSE
            self.flag_update()

    cdef void prebuild_ellipse(self):
        cdef double x, y, w, h, angle_start = 0, angle_end = 360
        cdef int angle_dir, segments = 0
        cdef double angle_range
        cdef tuple args = self._mode_args

        if len(args) == 4:
            x, y, w, h = args
        elif len(args) == 6:
            x, y, w, h, angle_start, angle_end = args
        elif len(args) == 7:
            x, y, w, h, angle_start, angle_end, segments = args
            segments += 2
        else:
            assert(0)

        if angle_end > angle_start:
            angle_dir = 1
        else:
            angle_dir = -1
        if segments == 0:
            segments = int(abs(angle_end - angle_start) / 2) + 3
        # rad = deg * (pi / 180), where pi/180 = 0.0174...
        angle_start = angle_start * 0.017453292519943295
        angle_end = angle_end * 0.017453292519943295
        angle_range = abs(angle_end - angle_start) / (segments - 2)

        cdef list points = [0, ] * (segments + 2)
        cdef double angle
        cdef double rx = w * 0.5
        cdef double ry = h * 0.5
        for i in xrange(0, segments + 2, 2):
            angle = angle_start + (angle_dir * (i - 1) * angle_range)
            points[i] = (x + rx) + (rx * sin(angle))
            points[i + 1] = (y + ry) + (ry * cos(angle))

        self._points = points


    property circle:
        '''Use this property to build a circle, without calculate the
        :data:`points`. You can only set this property, not get it.

        The argument must be a tuple of (center_x, center_y, radius, angle_start,
        angle_end, segments):

        * center_x and center_y represent the center of the circle
        * radius represent the radius of the circle
        * (optional) angle_start and angle_end are in degree. The default
            value is 0 and 360.
        * (optional) segments is the precision of the ellipse. The default
            value is calculated from the range between angle.

        Note that it's up to you to :data:`close` the circle or not.

        For example, for building a simple ellipse, in python::

            # simple circle
            Line(circle=(150, 150, 50))

            # only from 90 to 180 degrees
            Line(circle=(150, 150, 50, 90, 180))

            # only from 90 to 180 degrees, with few segments
            Line(circle=(150, 150, 50, 90, 180, 20))

        .. versionadded:: 1.4.1
        '''

        def __set__(self, args):
            if args == None:
                raise GraphicException(
                        'Invalid circle value: {0!r}'.format(args))
            if len(args) not in (3, 5, 6):
                raise GraphicException('Invalid number of arguments: '
                        '{0} instead of 3, 5 or 6.'.format(len(args)))
            self._mode_args = tuple(args)
            self._mode = LINE_MODE_CIRCLE
            self.flag_update()

    cdef void prebuild_circle(self):
        cdef double x, y, r, angle_start = 0, angle_end = 360
        cdef int angle_dir, segments = 0
        cdef double angle_range
        cdef tuple args = self._mode_args

        if len(args) == 3:
            x, y, r = args
        elif len(args) == 5:
            x, y, r, angle_start, angle_end = args
        elif len(args) == 6:
            x, y, r, angle_start, angle_end, segments = args
            segments += 2
        else:
            assert(0)

        if angle_end > angle_start:
            angle_dir = 1
        else:
            angle_dir = -1
        if segments == 0:
            segments = int(abs(angle_end - angle_start) / 2) + 3
        # rad = deg * (pi / 180), where pi/180 = 0.0174...
        angle_start = angle_start * 0.017453292519943295
        angle_end = angle_end * 0.017453292519943295
        angle_range = abs(angle_end - angle_start) / (segments - 2)

        cdef list points = [0, ] * (segments + 2)
        cdef double angle
        for i in xrange(0, segments + 2, 2):
            angle = angle_start + (angle_dir * (i - 1) * angle_range)
            points[i] = x + (r * sin(angle))
            points[i + 1] = y + (r * cos(angle))
        self._points = points

    property rectangle:
        '''Use this property to build a rectangle, without calculating the
        :data:`points`. You can only set this property, not get it.

        The argument must be a tuple of (x, y, width, height)
        angle_end, segments):

        * x and y represent the bottom-left position of the rectangle
        * width and height represent the size

        The line is automatically closed.

        Usage::

            Line(rectangle=(0, 0, 200, 200))

        .. versionadded:: 1.4.1
        '''

        def __set__(self, args):
            if args == None:
                raise GraphicException(
                        'Invalid rectangle value: {0!r}'.format(args))
            if len(args) != 4:
                raise GraphicException('Invalid number of arguments: '
                        '{0} instead of 4.'.format(len(args)))
            self._mode_args = tuple(args)
            self._mode = LINE_MODE_RECTANGLE
            self.flag_update()

    cdef void prebuild_rectangle(self):
        cdef double x, y, width, height
        cdef int angle_dir, segments = 0
        cdef double angle_range
        cdef tuple args = self._mode_args

        if args == None:
            raise GraphicException(
                    'Invalid ellipse value: {0!r}'.format(args))

        if len(args) == 4:
            x, y, width, height = args
        else:
            assert(0)

        self._points = [x, y, x + width, y, x + width, y + height, x, y + height]
        self._close = 1

    property bezier:
        '''Use this property to build a bezier line, without calculating the
        :data:`points`. You can only set this property, not get it.

        The argument must be a tuple of 2n elements, n being the number of points.

        Usage::

            Line(bezier=(x1, y1, x2, y2, x3, y3)

        .. versionadded:: 1.4.2

        .. note:: Bezier lines calculations are inexpensive for a low number of
            points, but complexity is quadratic, so lines with a lot of points
            can be very expensive to build, use with care!
        '''

        def __set__(self, args):
            if args == None or len(args) % 2:
                raise GraphicException(
                        'Invalid bezier value: {0!r}'.format(args))
            self._mode_args = tuple(args)
            self._mode = LINE_MODE_BEZIER
            self.flag_update()

    cdef void prebuild_bezier(self):
        cdef double x, y, l
        cdef int segments = self._bezier_precision
        cdef list T = list(self._mode_args)[:]

        self._points = []
        for x in xrange(segments):
            l = x / (1.0 * segments)
            # http://en.wikipedia.org/wiki/De_Casteljau%27s_algorithm
            # as the list is in the form of (x1, y1, x2, y2...) iteration is
            # done on each item and the current item (xn or yn) in the list is
            # replaced with a calculation of "xn + x(n+1) - xn" x(n+1) is
            # placed at n+2. Each iteration makes the list one item shorter
            for i in range(1, len(T)):
                for j in xrange(len(T) - 2*i):
                    T[j] = T[j] + (T[j+2] - T[j]) * l

            # we got the coordinates of the point in T[0] and T[1]
            self._points.append(T[0])
            self._points.append(T[1])

        # add one last point to join the curve to the end
        self._points.append(T[-2])
        self._points.append(T[-1])

    property bezier_precision:
        '''Number of iteration for drawing the bezier between 2 segments,
        default to 180. The bezier_precision must be at least 1.

        .. versionadded:: 1.4.2
        '''

        def __get__(self):
            return self._bezier_precision

        def __set__(self, value):
            if value < 1:
                raise GraphicException('Invalid bezier_precision value, must be >= 1')
            self._bezier_precision = int(value)
            self.flag_update()
